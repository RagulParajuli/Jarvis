#include "device_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <endpointvolume.h>
#include <knownfolders.h>
#include <mmdeviceapi.h>
#include <shlobj.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cwctype>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

// Windows half of the `jarvis/device` channel.
//
// Every handler answers with the same `{success: bool, ...}` envelope the
// Android implementation uses, so lib/support/device_rpc.dart does not need to
// know which platform it is talking to. Nothing here throws: a missing app, an
// unreadable folder or an absent audio device comes back as `success: false`
// with a message the agent can say out loud.

namespace {

namespace fs = std::filesystem;

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResult;

// --- Envelope helpers --------------------------------------------------------

EncodableMap Ok() {
  return EncodableMap{{EncodableValue("success"), EncodableValue(true)}};
}

EncodableMap Failure(const std::string& message) {
  return EncodableMap{{EncodableValue("success"), EncodableValue(false)},
                      {EncodableValue("error"), EncodableValue(message)}};
}

void Put(EncodableMap* map, const char* key, EncodableValue value) {
  (*map)[EncodableValue(key)] = std::move(value);
}

// --- Text helpers ------------------------------------------------------------

// Windows filenames are UTF-16 while the channel carries UTF-8, and the user
// speaks Tamil and Hindi as well as English, so both directions are converted
// properly rather than treating everything as ASCII.
std::wstring Widen(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int size = ::MultiByteToWideChar(
      CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                        wide.data(), size);
  return wide;
}

std::string Narrow(const std::wstring& text) {
  if (text.empty()) {
    return std::string();
  }
  const int size =
      ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                            static_cast<int>(text.size()), nullptr, 0, nullptr,
                            nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string narrow(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                        narrow.data(), size, nullptr, nullptr);
  return narrow;
}

std::wstring Lower(std::wstring text) {
  std::transform(text.begin(), text.end(), text.begin(), [](wchar_t character) {
    return static_cast<wchar_t>(std::towlower(character));
  });
  return text;
}

// Splits a spoken query into lowercase words, exactly like the Android
// MediaStore `LIKE %query%` and the agent's own file search.
std::vector<std::wstring> QueryTerms(const std::string& query) {
  std::vector<std::wstring> terms;
  std::wstring current;
  for (const wchar_t character : Lower(Widen(query))) {
    if (std::iswspace(character) != 0) {
      if (!current.empty()) {
        terms.push_back(current);
        current.clear();
      }
      continue;
    }
    current.push_back(character);
  }
  if (!current.empty()) {
    terms.push_back(current);
  }
  return terms;
}

// --- Local media -------------------------------------------------------------

constexpr std::size_t kMaxMatches = 20;
constexpr std::size_t kMaxDirectories = 4000;
constexpr std::chrono::milliseconds kSearchBudget{4000};

const std::vector<std::wstring>& VideoExtensions() {
  static const std::vector<std::wstring> kExtensions = {
      L".mp4", L".mkv", L".avi", L".mov", L".wmv", L".flv", L".webm",
      L".m4v", L".mpg", L".mpeg", L".ts", L".3gp", L".vob"};
  return kExtensions;
}

const std::vector<std::wstring>& AudioExtensions() {
  static const std::vector<std::wstring> kExtensions = {
      L".mp3",  L".wav", L".flac", L".m4a", L".aac",
      L".ogg",  L".opus", L".wma", L".aiff", L".mid"};
  return kExtensions;
}

// Matches the Android `kind == "video"` split: anything that is not obviously
// a movie is treated as music, which is what the agent's `play_media` defaults
// to.
bool WantsVideo(const std::string& kind) {
  const std::wstring lowered = Lower(Widen(kind));
  return lowered == L"video" || lowered == L"movie" || lowered == L"film";
}

bool HasMediaExtension(const std::wstring& lowered_name, bool video) {
  const std::vector<std::wstring>& extensions =
      video ? VideoExtensions() : AudioExtensions();
  return std::any_of(extensions.begin(), extensions.end(),
                     [&lowered_name](const std::wstring& extension) {
                       return lowered_name.size() > extension.size() &&
                              lowered_name.compare(lowered_name.size() -
                                                       extension.size(),
                                                   extension.size(),
                                                   extension) == 0;
                     });
}

// Folders that are never worth walking into, mirroring the agent's pc.py.
bool IsSkippedDirectory(const std::wstring& lowered_name) {
  static const std::vector<std::wstring> kSkipped = {
      L"windows",     L"$recycle.bin", L"system volume information",
      L"recovery",    L"program files", L"program files (x86)",
      L"programdata", L"appdata",       L"node_modules",
      L".git",        L"__pycache__",   L".venv",
      L"venv",        L".next",         L"perflogs"};
  return std::find(kSkipped.begin(), kSkipped.end(), lowered_name) !=
         kSkipped.end();
}

// The folders the user actually keeps media in. Restricting the search here
// keeps a voice request fast and avoids walking the whole disk.
std::vector<fs::path> MediaRoots() {
  const KNOWNFOLDERID* const kIds[] = {&FOLDERID_Music, &FOLDERID_Videos,
                                       &FOLDERID_Downloads, &FOLDERID_Desktop,
                                       &FOLDERID_Documents};
  std::vector<fs::path> roots;
  for (const KNOWNFOLDERID* id : kIds) {
    PWSTR raw = nullptr;
    if (FAILED(::SHGetKnownFolderPath(*id, KF_FLAG_DEFAULT, nullptr, &raw))) {
      continue;
    }
    if (raw != nullptr) {
      roots.emplace_back(fs::path(raw));
      ::CoTaskMemFree(raw);
    }
  }
  return roots;
}

struct MediaMatch {
  std::string name;
  std::string path;
};

struct MediaSearch {
  std::vector<MediaMatch> matches;
  bool timed_out = false;
  std::string error;
};

// Runs on a worker thread: the caller must not block the platform thread while
// a large Downloads folder is walked. The roots are resolved by the caller
// because SHGetKnownFolderPath needs the COM apartment the platform thread
// already has.
MediaSearch SearchMediaFiles(const std::string& query, bool video,
                             const std::vector<fs::path>& roots) {
  MediaSearch found;
  const std::vector<std::wstring> terms = QueryTerms(query);
  if (terms.empty()) {
    found.error = "nothing to search for was named";
    return found;
  }

  const std::chrono::steady_clock::time_point deadline =
      std::chrono::steady_clock::now() + kSearchBudget;
  std::vector<fs::path> pending = roots;
  std::size_t visited = 0;
  std::size_t next = 0;

  while (next < pending.size() && found.matches.size() < kMaxMatches &&
         visited < kMaxDirectories) {
    if (std::chrono::steady_clock::now() > deadline) {
      found.timed_out = true;
      break;
    }

    const fs::path current = pending[next];
    ++next;
    ++visited;

    std::error_code list_error;
    fs::directory_iterator entry_iterator(
        current, fs::directory_options::skip_permission_denied, list_error);
    if (list_error) {
      continue;
    }

    const fs::directory_iterator end;
    while (entry_iterator != end && found.matches.size() < kMaxMatches) {
      std::error_code type_error;
      const fs::path entry_path = entry_iterator->path();
      const std::wstring entry_name = entry_path.filename().wstring();
      const std::wstring lowered_name = Lower(entry_name);

      if (entry_iterator->is_directory(type_error)) {
        if (!lowered_name.empty() && lowered_name[0] != L'$' &&
            !IsSkippedDirectory(lowered_name)) {
          pending.push_back(entry_path);
        }
      } else if (!type_error && HasMediaExtension(lowered_name, video)) {
        bool all_terms_present = true;
        for (const std::wstring& term : terms) {
          if (lowered_name.find(term) == std::wstring::npos) {
            all_terms_present = false;
            break;
          }
        }
        if (all_terms_present) {
          found.matches.push_back(
              MediaMatch{Narrow(entry_name), Narrow(entry_path.wstring())});
        }
      }

      std::error_code step_error;
      entry_iterator.increment(step_error);
      if (step_error) {
        break;
      }
    }
  }

  return found;
}

EncodableList MatchList(const std::vector<MediaMatch>& matches) {
  EncodableList list;
  list.reserve(matches.size());
  for (const MediaMatch& match : matches) {
    EncodableMap entry;
    Put(&entry, "name", EncodableValue(match.name));
    Put(&entry, "path", EncodableValue(match.path));
    list.push_back(EncodableValue(entry));
  }
  return list;
}

// --- Apps --------------------------------------------------------------------

// Friendly spoken names mapped to what actually launches them. Anything not
// listed here is looked up in the registry and the Start Menu before falling
// back to the app's website, which is what the agent already does itself when
// it runs on the same computer.
const std::vector<std::pair<std::wstring, std::wstring>>& KnownApps() {
  static const std::vector<std::pair<std::wstring, std::wstring>> kApps = {
      {L"notepad", L"notepad.exe"},
      {L"calculator", L"calc.exe"},
      {L"calc", L"calc.exe"},
      {L"paint", L"mspaint.exe"},
      {L"wordpad", L"write.exe"},
      {L"cmd", L"cmd.exe"},
      {L"command prompt", L"cmd.exe"},
      {L"powershell", L"powershell.exe"},
      {L"terminal", L"wt.exe"},
      {L"windows terminal", L"wt.exe"},
      {L"explorer", L"explorer.exe"},
      {L"file explorer", L"explorer.exe"},
      {L"files", L"explorer.exe"},
      {L"task manager", L"taskmgr.exe"},
      {L"control panel", L"control.exe"},
      {L"settings", L"ms-settings:"},
      {L"spotify", L"spotify:"},
      {L"photos", L"ms-photos:"},
      {L"camera", L"microsoft.windows.camera:"},
      {L"store", L"ms-windows-store:"},
      {L"microsoft store", L"ms-windows-store:"},
      {L"xbox", L"xbox:"},
      {L"clock", L"ms-clock:"},
      {L"mail", L"outlookmail:"},
  };
  return kApps;
}

// The registry is the canonical place Windows records where an executable
// lives, so "chrome" or "code" resolve without a hardcoded install path.
bool LookupAppPath(const std::wstring& executable, std::wstring* resolved) {
  const HKEY kRoots[] = {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
  for (const HKEY root : kRoots) {
    const std::wstring subkey =
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\" +
        executable;
    wchar_t buffer[2048] = {};
    DWORD size = static_cast<DWORD>(sizeof(buffer));
    const LSTATUS status = ::RegGetValueW(root, subkey.c_str(), nullptr,
                                          RRF_RT_REG_SZ, nullptr, buffer,
                                          &size);
    if (status == ERROR_SUCCESS && buffer[0] != L'\0') {
      *resolved = buffer;
      return true;
    }
  }
  return false;
}

// Start Menu shortcuts are how Store apps and installers that skip the
// registry are launched, so a plain name like "netflix" still works.
std::wstring FindStartMenuShortcut(const std::wstring& wanted) {
  const KNOWNFOLDERID* const kIds[] = {&FOLDERID_Programs,
                                       &FOLDERID_CommonPrograms};
  std::wstring partial;
  for (const KNOWNFOLDERID* id : kIds) {
    PWSTR raw = nullptr;
    if (FAILED(::SHGetKnownFolderPath(*id, KF_FLAG_DEFAULT, nullptr, &raw))) {
      continue;
    }
    if (raw == nullptr) {
      continue;
    }
    const fs::path root(raw);
    ::CoTaskMemFree(raw);

    std::error_code list_error;
    fs::recursive_directory_iterator shortcut_iterator(
        root, fs::directory_options::skip_permission_denied, list_error);
    if (list_error) {
      continue;
    }

    const fs::recursive_directory_iterator end;
    std::size_t visited = 0;
    while (shortcut_iterator != end && visited < 5000) {
      ++visited;
      std::error_code type_error;
      const fs::path shortcut_path = shortcut_iterator->path();
      if (shortcut_iterator->is_regular_file(type_error) &&
          Lower(shortcut_path.extension().wstring()) == L".lnk") {
        const std::wstring stem = Lower(shortcut_path.stem().wstring());
        if (stem == wanted) {
          return shortcut_path.wstring();
        }
        if (partial.empty() && stem.find(wanted) != std::wstring::npos) {
          partial = shortcut_path.wstring();
        }
      }
      std::error_code step_error;
      shortcut_iterator.increment(step_error);
      if (step_error) {
        break;
      }
    }
  }
  return partial;
}

// ShellExecuteW returns a value above 32 on success; everything at or below it
// is an error code, which is the documented Windows convention.
bool LaunchTarget(const std::wstring& target) {
  if (target.empty()) {
    return false;
  }
  const HINSTANCE launched = ::ShellExecuteW(nullptr, L"open", target.c_str(),
                                             nullptr, nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<INT_PTR>(launched) > 32;
}

// The agent already treats an unknown app name as a website request when it
// runs on the user's computer, so the same fallback keeps "open youtube"
// working instead of failing now that Windows answers `open_app` itself.
std::string WebsiteSlug(const std::string& name) {
  std::string slug;
  for (const char character : name) {
    if (character >= 'a' && character <= 'z') {
      slug.push_back(character);
    } else if (character >= 'A' && character <= 'Z') {
      slug.push_back(static_cast<char>(character - 'A' + 'a'));
    } else if (character >= '0' && character <= '9') {
      slug.push_back(character);
    }
  }
  return slug;
}

EncodableMap OpenApp(const std::string& name) {
  const std::wstring lowered = Lower(Widen(name));
  if (lowered.empty()) {
    return Failure("no app was named");
  }

  for (const std::pair<std::wstring, std::wstring>& known : KnownApps()) {
    if (known.first != lowered) {
      continue;
    }
    if (LaunchTarget(known.second)) {
      EncodableMap reply = Ok();
      Put(&reply, "app", EncodableValue(name));
      Put(&reply, "target", EncodableValue(Narrow(known.second)));
      return reply;
    }
  }

  // "google chrome" and similar two-word names resolve to chrome.exe.
  std::vector<std::wstring> candidates;
  candidates.push_back(lowered + L".exe");
  const std::size_t last_space = lowered.find_last_of(L' ');
  if (last_space != std::wstring::npos && last_space + 1 < lowered.size()) {
    candidates.push_back(lowered.substr(last_space + 1) + L".exe");
  }
  for (const std::wstring& candidate : candidates) {
    std::wstring resolved;
    if (LookupAppPath(candidate, &resolved) && LaunchTarget(resolved)) {
      EncodableMap reply = Ok();
      Put(&reply, "app", EncodableValue(name));
      Put(&reply, "target", EncodableValue(Narrow(resolved)));
      return reply;
    }
  }

  const std::wstring shortcut = FindStartMenuShortcut(lowered);
  if (!shortcut.empty() && LaunchTarget(shortcut)) {
    EncodableMap reply = Ok();
    Put(&reply, "app", EncodableValue(name));
    Put(&reply, "target", EncodableValue(Narrow(shortcut)));
    return reply;
  }

  const std::string slug = WebsiteSlug(name);
  if (!slug.empty()) {
    const std::wstring website = L"https://www." + Widen(slug) + L".com";
    if (LaunchTarget(website)) {
      EncodableMap reply = Ok();
      Put(&reply, "app", EncodableValue(name));
      Put(&reply, "target", EncodableValue(Narrow(website)));
      Put(&reply, "website", EncodableValue(true));
      Put(&reply, "message",
          EncodableValue("I couldn't find an app called " + name +
                         " on this computer, so I opened its website instead."));
      return reply;
    }
  }

  return Failure("I couldn't find an app called " + name +
                 " on this computer");
}

// --- Volume ------------------------------------------------------------------

// main.cpp already puts the platform thread in a single-threaded apartment, so
// this only ever balances its own reference count.
class ComScope {
 public:
  ComScope() : result_(::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)) {}
  ~ComScope() {
    if (SUCCEEDED(result_)) {
      ::CoUninitialize();
    }
  }

  ComScope(const ComScope&) = delete;
  ComScope& operator=(const ComScope&) = delete;

 private:
  HRESULT result_;
};

EncodableMap ControlVolume(const std::string& value) {
  const std::wstring lowered = Lower(Widen(value));

  ComScope com_scope;

  Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT status = ::CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
      IID_PPV_ARGS(enumerator.GetAddressOf()));
  if (FAILED(status) || !enumerator) {
    return Failure("this computer could not reach its audio devices");
  }

  Microsoft::WRL::ComPtr<IMMDevice> device;
  status = enumerator->GetDefaultAudioEndpoint(eRender, eConsole,
                                               device.GetAddressOf());
  if (FAILED(status) || !device) {
    return Failure("there is no audio output device to control");
  }

  Microsoft::WRL::ComPtr<IAudioEndpointVolume> endpoint;
  status = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                            reinterpret_cast<void**>(endpoint.GetAddressOf()));
  if (FAILED(status) || !endpoint) {
    return Failure("the volume of this computer could not be read");
  }

  if (lowered == L"up" || lowered == L"increase") {
    endpoint->StepUp();
  } else if (lowered == L"down" || lowered == L"decrease") {
    endpoint->StepDown();
  } else if (lowered == L"mute" || lowered == L"silent") {
    endpoint->SetMute(TRUE, nullptr);
  } else if (lowered == L"unmute") {
    endpoint->SetMute(FALSE, nullptr);
  } else if (lowered == L"max") {
    endpoint->SetMasterVolumeLevelScalar(1.0f, nullptr);
  } else {
    wchar_t* remainder = nullptr;
    const long percent = std::wcstol(lowered.c_str(), &remainder, 10);
    if (lowered.empty() || remainder == nullptr || *remainder != L'\0' ||
        percent < 0 || percent > 100) {
      return Failure(value + " is not a volume level");
    }
    endpoint->SetMasterVolumeLevelScalar(static_cast<float>(percent) / 100.0f,
                                         nullptr);
  }

  float level = 0.0f;
  endpoint->GetMasterVolumeLevelScalar(&level);
  BOOL muted = FALSE;
  endpoint->GetMute(&muted);

  EncodableMap reply = Ok();
  Put(&reply, "feature", EncodableValue("volume"));
  Put(&reply, "value", EncodableValue(value));
  Put(&reply, "percent",
      EncodableValue(static_cast<int32_t>(level * 100.0f + 0.5f)));
  Put(&reply, "muted", EncodableValue(muted != FALSE));
  return reply;
}

EncodableMap ControlDevice(const std::string& feature,
                           const std::string& value) {
  const std::wstring lowered = Lower(Widen(feature));
  if (lowered == L"volume") {
    return ControlVolume(value);
  }
  if (lowered == L"flashlight" || lowered == L"torch") {
    return Failure("this computer has no torch to switch on");
  }
  if (lowered == L"media") {
    return Failure(
        "this computer cannot control media playback through the assistant "
        "yet; use the player's own controls");
  }
  if (lowered == L"wifi" || lowered == L"bluetooth") {
    return Failure("this computer does not let the assistant switch " + feature +
                   " on or off");
  }
  return Failure("this computer cannot control " + feature);
}

// --- Media playback ----------------------------------------------------------

void ReplyWithMediaSearch(
    const std::shared_ptr<MethodResult<EncodableValue>>& result,
    const MediaSearch& found, const std::string& query, bool play) {
  if (!found.error.empty()) {
    result->Success(EncodableValue(Failure(found.error)));
    return;
  }
  if (found.matches.empty()) {
    result->Success(EncodableValue(
        Failure("I couldn't find anything called " + query +
                " on this computer")));
    return;
  }

  if (!play) {
    EncodableMap reply = Ok();
    Put(&reply, "matches", EncodableValue(MatchList(found.matches)));
    Put(&reply, "count",
        EncodableValue(static_cast<int32_t>(found.matches.size())));
    Put(&reply, "timed_out", EncodableValue(found.timed_out));
    result->Success(EncodableValue(reply));
    return;
  }

  // Hand the file to whatever the user has set as the default player, which is
  // the Windows equivalent of Android's ACTION_VIEW on a MediaStore entry.
  const MediaMatch& chosen = found.matches.front();
  if (!LaunchTarget(Widen(chosen.path))) {
    result->Success(EncodableValue(
        Failure("nothing on this computer can play " + chosen.name)));
    return;
  }

  EncodableMap reply = Ok();
  Put(&reply, "title", EncodableValue(chosen.name));
  Put(&reply, "path", EncodableValue(chosen.path));
  Put(&reply, "matches", EncodableValue(MatchList(found.matches)));
  result->Success(EncodableValue(reply));
}

void StartMediaRequest(flutter::FlutterEngine* engine,
                       std::shared_ptr<MethodResult<EncodableValue>> result,
                       std::string query, bool video, bool play) {
  std::vector<fs::path> roots = MediaRoots();
  std::thread worker([engine, result, query, video, play, roots]() {
    const MediaSearch found = SearchMediaFiles(query, video, roots);
    engine->PostPlatformThreadTask([result, found, query, play]() {
      ReplyWithMediaSearch(result, found, query, play);
    });
  });
  worker.detach();
}

// --- Argument helpers --------------------------------------------------------

std::string StringArgument(const EncodableValue* arguments, const char* key) {
  if (arguments == nullptr) {
    return std::string();
  }
  const EncodableMap* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) {
    return std::string();
  }
  const EncodableMap::const_iterator found = map->find(EncodableValue(key));
  if (found == map->end()) {
    return std::string();
  }
  const std::string* text = std::get_if<std::string>(&found->second);
  return text != nullptr ? *text : std::string();
}

void Dispatch(flutter::FlutterEngine* engine,
              const MethodCall<EncodableValue>& call,
              std::unique_ptr<MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const EncodableValue* arguments = call.arguments();

  if (method == "openApp") {
    result->Success(EncodableValue(OpenApp(StringArgument(arguments, "app"))));
    return;
  }

  if (method == "playMedia" || method == "searchMedia") {
    const std::string query = StringArgument(arguments, "query");
    if (query.empty()) {
      result->Success(EncodableValue(Failure(
          method == "playMedia" ? "nothing to play was named"
                                : "nothing to search for was named")));
      return;
    }
    StartMediaRequest(
        engine, std::shared_ptr<MethodResult<EncodableValue>>(result.release()),
        query, WantsVideo(StringArgument(arguments, "kind")),
        method == "playMedia");
    return;
  }

  if (method == "deviceControl") {
    result->Success(EncodableValue(
        ControlDevice(StringArgument(arguments, "feature"),
                      StringArgument(arguments, "value"))));
    return;
  }

  // open_url is served by url_launcher in Dart and send_whatsapp is not
  // advertised on Windows, so reaching here means the build was asked for
  // something it never claimed to support.
  result->Success(
      EncodableValue(Failure("this computer cannot handle " + method)));
}

// Deliberately a raw pointer that is never freed: MethodChannel's destructor
// unregisters through the engine's messenger, which is already gone by the time
// static destructors run at exit. One object for the life of the process is the
// simplest safe lifetime here.
flutter::MethodChannel<EncodableValue>* g_channel = nullptr;

}  // namespace

void RegisterDeviceChannel(flutter::FlutterEngine* engine) {
  if (engine == nullptr || g_channel != nullptr) {
    return;
  }

  g_channel = new flutter::MethodChannel<EncodableValue>(
      engine->messenger(), "jarvis/device",
      &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [engine](const MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult<EncodableValue>> result) {
        Dispatch(engine, call, std::move(result));
      });
}
