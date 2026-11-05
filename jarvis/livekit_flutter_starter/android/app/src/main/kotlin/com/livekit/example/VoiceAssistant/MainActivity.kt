package com.livekit.example.VoiceAssistantFlutter

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.ContactsContract
import android.provider.MediaStore
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.view.KeyEvent
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URLEncoder
import java.security.KeyStore
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties

/**
 * Native half of the `jarvis/device` channel declared in [DeviceBridge].
 *
 * The agent runs on the user's computer, so it cannot launch an app on the phone
 * or play a song that only exists there. Everything the assistant asks for over
 * RPC lands here instead, which is what makes "open youtube" spoken into a phone
 * act on the phone.
 *
 * No handler throws: failures come back as `{success: false, error: …}` so the
 * agent can tell the user what went wrong rather than going silent.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "jarvis/device"
        const val PERMISSION_REQUEST = 4701
        const val ACCESS_CODE_KEY_ALIAS = "jarvis_access_code_key"
        const val ACCESS_CODE_PREF = "jarvis_secure_preferences"
        const val ACCESS_CODE_PREF_KEY = "encrypted_access_code"

        /** Friendly names mapped to the package phones normally ship with. */
        val KNOWN_APPS = mapOf(
            "youtube" to "com.google.android.youtube",
            "youtube music" to "com.google.android.apps.youtube.music",
            "chrome" to "com.android.chrome",
            "browser" to "com.android.chrome",
            "whatsapp" to "com.whatsapp",
            "gmail" to "com.google.android.gm",
            "maps" to "com.google.android.apps.maps",
            "google maps" to "com.google.android.apps.maps",
            "spotify" to "com.spotify.music",
            "instagram" to "com.instagram.android",
            "facebook" to "com.facebook.katana",
            "telegram" to "org.telegram.messenger",
            "netflix" to "com.netflix.mediaclient",
            "play store" to "com.android.vending",
            "photos" to "com.google.android.apps.photos",
            "gallery" to "com.google.android.apps.photos",
            "settings" to "com.android.settings",
            "camera" to "com.android.camera2",
            "phone" to "com.android.dialer",
            "messages" to "com.google.android.apps.messaging",
        )
    }

    private var pendingPermission: ((Boolean) -> Unit)? = null

    // ── Offline voice ───────────────────────────────────────────────────────
    // With no internet the LiveKit session and the cloud model are both gone,
    // so the phone's own speech engine takes over. Using the platform APIs
    // instead of a plugin keeps the APK small, and `preferOffline` asks Android
    // to stay on the device rather than calling out to a server.
    private var speechChannel: MethodChannel? = null
    private var recognizer: SpeechRecognizer? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var pendingSpeech: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        speechChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        speechChannel?.setMethodCallHandler { call, result -> dispatch(call, result) }
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "openApp" -> openApp(call.argument("app"), result)
                "playMedia" -> findMedia(call.argument("query"), call.argument("kind"), result, play = true)
                "searchMedia" -> findMedia(call.argument("query"), call.argument("kind"), result, play = false)
                "sendWhatsapp" -> sendWhatsapp(call.argument("contact"), call.argument("message"), result)
                "deviceControl" -> deviceControl(call.argument("feature"), call.argument("value"), result)
                "openSettings" -> openSettings(call.argument("section"), result)
                "readSavedAccessCode" -> result.success(readSavedAccessCode())
                "saveAccessCode" -> {
                    saveAccessCode(call.argument<String>("value").orEmpty())
                    result.success(null)
                }
                "speechAvailable" -> result.success(
                    ok("available" to SpeechRecognizer.isRecognitionAvailable(this)),
                )
                "listen" -> startListening(call, result)
                "stopListening" -> {
                    stopRecognizer()
                    result.success(ok("listening" to false))
                }
                "speak" -> speak(call.argument("text"), result)
                "stopSpeaking" -> {
                    tts?.stop()
                    result.success(ok())
                }
                else -> result.success(failure("this device cannot handle ${call.method}"))
            }
        } catch (error: Exception) {
            if (call.method == "readSavedAccessCode" || call.method == "saveAccessCode") {
                result.error("secure_storage", error.message ?: error.javaClass.simpleName, null)
            } else {
                result.success(failure(error.message ?: error.javaClass.simpleName))
            }
        }
    }

    // ── Apps ────────────────────────────────────────────────────────────────

    private fun openApp(name: String?, result: MethodChannel.Result) {
        if (name.isNullOrBlank()) {
            result.success(failure("no app was named"))
            return
        }

        val packageName = resolvePackage(name)
        if (packageName == null) {
            // Nothing installed matched, so offer the store rather than failing flat.
            val market = Uri.parse("market://search?q=${Uri.encode(name)}")
            val store = Uri.parse("https://play.google.com/store/search?q=${Uri.encode(name)}")
            if (launchUri(market) || launchUri(store)) {
                result.success(ok("app" to name, "store" to true))
            } else {
                result.success(failure("I couldn't find an app called $name on this device"))
            }
            return
        }

        val intent = packageManager.getLaunchIntentForPackage(packageName)
        if (intent == null) {
            result.success(failure("$name is installed but has no screen to open"))
            return
        }

        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        result.success(ok("app" to name, "package" to packageName))
    }

    /** Turns a spoken name like "youtube" into an installed package name. */
    private fun resolvePackage(name: String): String? {
        val wanted = name.lowercase().trim()

        KNOWN_APPS[wanted]?.let { known ->
            if (isInstalled(known)) return known
        }

        // An explicit package name is taken at face value.
        if (wanted.contains('.') && isInstalled(wanted)) return wanted

        // Otherwise match on the label the launcher shows.
        val launchIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return packageManager.queryIntentActivities(launchIntent, 0)
            .mapNotNull { info ->
                val label = info.loadLabel(packageManager).toString().lowercase()
                val score = when {
                    label == wanted -> 3
                    label.startsWith(wanted) -> 2
                    label.contains(wanted) -> 1
                    else -> 0
                }
                if (score == 0) null else info.activityInfo.packageName to score
            }
            .maxByOrNull { it.second }
            ?.first
    }

    private fun isInstalled(packageName: String): Boolean =
        packageManager.getLaunchIntentForPackage(packageName) != null

    // ── Local media ─────────────────────────────────────────────────────────

    private fun findMedia(
        query: String?,
        kind: String?,
        result: MethodChannel.Result,
        play: Boolean,
    ) {
        if (query.isNullOrBlank()) {
            result.success(failure("nothing to search for was named"))
            return
        }

        ensurePermissions(mediaPermissions()) { granted ->
            if (!granted) {
                result.success(failure("I need permission to read this device's files first"))
                return@ensurePermissions
            }

            val matches = queryMedia(query, kind)
            if (matches.isEmpty()) {
                result.success(failure("I couldn't find anything called $query on this device"))
                return@ensurePermissions
            }

            if (!play) {
                result.success(ok("matches" to matches))
                return@ensurePermissions
            }

            val first = matches.first()
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse(first["uri"] as String), first["mime"] as String)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (startSafely(intent)) {
                result.success(ok("title" to first["name"], "uri" to first["uri"], "matches" to matches))
            } else {
                result.success(failure("nothing on this device can play ${first["name"]}"))
            }
        }
    }

    private fun queryMedia(query: String, kind: String?): List<Map<String, Any?>> {
        val movies = kind == "video"
        val collection = if (movies) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }
        val idColumn = if (movies) MediaStore.Video.Media._ID else MediaStore.Audio.Media._ID
        val titleColumn = if (movies) MediaStore.Video.Media.TITLE else MediaStore.Audio.Media.TITLE
        val mimeColumn = if (movies) MediaStore.Video.Media.MIME_TYPE else MediaStore.Audio.Media.MIME_TYPE

        val found = mutableListOf<Map<String, Any?>>()
        contentResolver.query(
            collection,
            arrayOf(idColumn, titleColumn, mimeColumn),
            "$titleColumn LIKE ?",
            arrayOf("%$query%"),
            "$titleColumn ASC",
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(idColumn)
            val titleIndex = cursor.getColumnIndexOrThrow(titleColumn)
            val mimeIndex = cursor.getColumnIndexOrThrow(mimeColumn)

            while (cursor.moveToNext() && found.size < 20) {
                val id = cursor.getLong(idIndex)
                found.add(
                    mapOf(
                        "name" to cursor.getString(titleIndex),
                        "mime" to (cursor.getString(mimeIndex) ?: if (movies) "video/*" else "audio/*"),
                        "uri" to Uri.withAppendedPath(collection, id.toString()).toString(),
                    ),
                )
            }
        }
        return found
    }

    // ── WhatsApp ────────────────────────────────────────────────────────────

    private fun sendWhatsapp(contact: String?, message: String?, result: MethodChannel.Result) {
        if (contact.isNullOrBlank()) {
            result.success(failure("no contact was named"))
            return
        }

        ensurePermissions(listOf(Manifest.permission.READ_CONTACTS)) { granted ->
            val text = URLEncoder.encode(message ?: "", "UTF-8")
            val number = if (granted) lookupPhone(contact) else null

            // WhatsApp has no silent-send API. With a number the chat opens with the
            // message written; without one the contact picker does, so the user only
            // ever makes the final tap.
            val uri = if (number != null) {
                Uri.parse("https://wa.me/$number?text=$text")
            } else {
                Uri.parse("https://wa.me/?text=$text")
            }

            if (launchUri(uri)) {
                result.success(ok("contact" to contact, "number" to number, "sent" to false))
            } else {
                result.success(failure("WhatsApp does not seem to be installed on this device"))
            }
        }
    }

    private fun lookupPhone(contact: String): String? {
        val uri = Uri.withAppendedPath(
            ContactsContract.CommonDataKinds.Phone.CONTENT_FILTER_URI,
            Uri.encode(contact),
        )

        contentResolver.query(
            uri,
            arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val digits = cursor.getString(0)?.filter { it.isDigit() }
                return digits?.ifBlank { null }
            }
        }
        return null
    }

    // ── Device features ─────────────────────────────────────────────────────

    private fun deviceControl(feature: String?, value: String?, result: MethodChannel.Result) {
        if (feature.isNullOrBlank()) {
            result.success(failure("no device feature was named"))
            return
        }

        result.success(
            when (feature.lowercase()) {
                "volume" -> setVolume(value.orEmpty())
                "flashlight", "torch" -> setTorch(value.orEmpty())
                "media" -> controlMedia(value.orEmpty())
                // Wi-Fi and Bluetooth cannot be flipped silently since Android 10;
                // the user has to confirm in system settings.
                "wifi", "bluetooth" -> failure(
                    "Android does not let an app switch $feature directly, so it has to be changed in Settings."
                )
                else -> failure("this device cannot control $feature")
            },
        )
    }

    private fun setVolume(value: String): Map<String, Any?> {
        val audio = getSystemService(AUDIO_SERVICE) as AudioManager
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)

        when (value.lowercase()) {
            "up", "increase" -> audio.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI,
            )
            "down", "decrease" -> audio.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI,
            )
            "mute", "silent" -> audio.setStreamVolume(AudioManager.STREAM_MUSIC, 0, AudioManager.FLAG_SHOW_UI)
            "unmute" -> audio.setStreamVolume(AudioManager.STREAM_MUSIC, max / 2, AudioManager.FLAG_SHOW_UI)
            "max" -> audio.setStreamVolume(AudioManager.STREAM_MUSIC, max, AudioManager.FLAG_SHOW_UI)
            else -> {
                val percent = value.toIntOrNull() ?: return failure("$value is not a volume level")
                val level = (max * percent / 100.0).toInt().coerceIn(0, max)
                audio.setStreamVolume(AudioManager.STREAM_MUSIC, level, AudioManager.FLAG_SHOW_UI)
                return ok("feature" to "volume", "level" to level, "percent" to percent)
            }
        }

        return ok("feature" to "volume", "value" to value)
    }

    private fun setTorch(value: String): Map<String, Any?> {
        val camera = getSystemService(CAMERA_SERVICE) as CameraManager
        val cameraId = camera.cameraIdList.firstOrNull { id ->
            camera.getCameraCharacteristics(id).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return failure("this device has no torch")

        val enabled = value.lowercase() != "off"
        camera.setTorchMode(cameraId, enabled)
        return ok("feature" to "flashlight", "value" to if (enabled) "on" else "off")
    }

    private fun controlMedia(value: String): Map<String, Any?> {
        val keyCode = when (value.lowercase()) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "next", "skip" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            "stop" -> KeyEvent.KEYCODE_MEDIA_STOP
            else -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
        }

        val audio = getSystemService(AUDIO_SERVICE) as AudioManager
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
        return ok("feature" to "media", "value" to value)
    }

    // ── Offline voice ───────────────────────────────────────────────────────

    private fun sendSpeechEvent(event: String, text: String = "") {
        speechChannel?.invokeMethod(
            "offlineSpeech",
            mapOf("event" to event, "text" to text),
        )
    }

    private fun startListening(call: MethodCall, result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.success(failure("speech recognition is not available on this device"))
            return
        }

        val language = call.argument<String>("language")
        val offline = call.argument<Boolean>("offline") ?: true

        ensurePermissions(listOf(Manifest.permission.RECORD_AUDIO)) { granted ->
            if (!granted) {
                result.success(failure("microphone permission is needed"))
                return@ensurePermissions
            }

            stopRecognizer()

            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)
                if (!language.isNullOrBlank()) putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, offline)
                }
            }

            val engine = if (
                offline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
            ) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
            } else {
                SpeechRecognizer.createSpeechRecognizer(this)
            }
            engine.setRecognitionListener(
                object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) {
                        sendSpeechEvent("ready")
                    }

                    override fun onBeginningOfSpeech() {
                        sendSpeechEvent("speech_start")
                    }

                    override fun onRmsChanged(rmsdB: Float) = Unit

                    override fun onBufferReceived(buffer: ByteArray?) = Unit

                    override fun onEndOfSpeech() {
                        sendSpeechEvent("speech_end")
                    }

                    override fun onError(error: Int) {
                        sendSpeechEvent("error", recognitionErrorMessage(error))
                        stopRecognizer()
                    }

                    override fun onResults(results: Bundle?) {
                        val text = results
                            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                            ?.firstOrNull()
                            .orEmpty()
                        sendSpeechEvent("final", text)
                        stopRecognizer()
                    }

                    override fun onPartialResults(partialResults: Bundle?) {
                        val text = partialResults
                            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                            ?.firstOrNull()
                            .orEmpty()
                        if (text.isNotBlank()) sendSpeechEvent("partial", text)
                    }

                    override fun onEvent(eventType: Int, params: Bundle?) = Unit
                },
            )
            recognizer = engine
            engine.startListening(intent)
            result.success(ok("listening" to true))
        }
    }

    private fun stopRecognizer() {
        val engine = recognizer
        recognizer = null
        if (engine == null) return
        try {
            engine.stopListening()
            engine.cancel()
        } catch (_: Exception) {
            // The engine was already gone; nothing to clean up.
        }
        engine.destroy()
    }

    private fun accessCodeKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(ACCESS_CODE_KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                ACCESS_CODE_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun readSavedAccessCode(): String? {
        val preferences = getSharedPreferences(ACCESS_CODE_PREF, MODE_PRIVATE)
        val encoded = preferences.getString(ACCESS_CODE_PREF_KEY, null) ?: return null
        return try {
            val payload = Base64.decode(encoded, Base64.NO_WRAP)
            if (payload.size <= 12) return null

            val iv = payload.copyOfRange(0, 12)
            val encrypted = payload.copyOfRange(12, payload.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, accessCodeKey(), GCMParameterSpec(128, iv))
            cipher.doFinal(encrypted).toString(Charsets.UTF_8)
        } catch (_: Exception) {
            // If Android restored ciphertext without its Keystore key, discard
            // it so the app can ask for the code again instead of crashing.
            preferences.edit().remove(ACCESS_CODE_PREF_KEY).apply()
            null
        }
    }

    private fun saveAccessCode(value: String) {
        if (value.isBlank()) return
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, accessCodeKey())
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val payload = cipher.iv + encrypted
        getSharedPreferences(ACCESS_CODE_PREF, MODE_PRIVATE)
            .edit()
            .putString(ACCESS_CODE_PREF_KEY, Base64.encodeToString(payload, Base64.NO_WRAP))
            .apply()
    }

    private fun recognitionErrorMessage(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_NO_MATCH,
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
        -> "no_speech"
        SpeechRecognizer.ERROR_NETWORK,
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
        -> "network"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permission"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
        SpeechRecognizer.ERROR_AUDIO -> "audio"
        else -> "speech_error"
    }

    private fun speak(text: String?, result: MethodChannel.Result) {
        if (text.isNullOrBlank()) {
            result.success(failure("nothing to say"))
            return
        }

        if (tts == null) {
            tts = TextToSpeech(this) { status ->
                ttsReady = status == TextToSpeech.SUCCESS
                if (!ttsReady) {
                    sendSpeechEvent("speech_error")
                } else {
                    tts?.setOnUtteranceProgressListener(
                        object : UtteranceProgressListener() {
                            override fun onStart(utteranceId: String?) {
                                runOnUiThread { sendSpeechEvent("speech_start") }
                            }

                            override fun onDone(utteranceId: String?) {
                                runOnUiThread { sendSpeechEvent("speech_done") }
                            }

                            override fun onError(utteranceId: String?) {
                                runOnUiThread { sendSpeechEvent("speech_error") }
                            }
                        },
                    )

                    pendingSpeech?.let { queued ->
                        pendingSpeech = null
                        utter(queued)
                    }
                }
            }
        }

        if (ttsReady) {
            utter(text)
            result.success(ok("speaking" to true))
        } else {
            // The engine is still warming up; it speaks this as soon as it can.
            pendingSpeech = text
            result.success(ok("speaking" to false, "queued" to true))
        }
    }

    private fun utter(text: String) {
        val locale = localeFor(text)
        val availability = tts?.setLanguage(locale)
        if (availability == TextToSpeech.LANG_MISSING_DATA || availability == TextToSpeech.LANG_NOT_SUPPORTED) {
            tts?.setLanguage(Locale.US)
        }
        tts?.setSpeechRate(1.0f)
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "jarvis-${System.nanoTime()}")
    }

    /** Picks a TTS locale from the script the reply is written in. */
    private fun localeFor(text: String): Locale {
        val hasTamil = text.any { it in '\u0B80'..'\u0BFF' }
        val hasDevanagari = text.any { it in '\u0900'..'\u097F' }
        val hasGurmukhi = text.any { it in '\u0A00'..'\u0A7F' }
        return when {
            hasTamil -> Locale.forLanguageTag("ta-IN")
            hasGurmukhi -> Locale.forLanguageTag("pa-IN")
            hasDevanagari -> Locale.forLanguageTag("hi-IN")
            else -> Locale.getDefault()
        }
    }

    private fun openSettings(section: String?, result: MethodChannel.Result) {
        val action = when (section?.lowercase()) {
            "wifi" -> Settings.ACTION_WIFI_SETTINGS
            "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
            else -> Settings.ACTION_SETTINGS
        }

        if (startSafely(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))) {
            result.success(ok("section" to (section ?: "settings")))
        } else {
            result.success(failure("I couldn't open Settings on this device"))
        }
    }

    override fun onDestroy() {
        stopRecognizer()
        tts?.stop()
        tts?.shutdown()
        tts = null
        speechChannel?.setMethodCallHandler(null)
        speechChannel = null
        super.onDestroy()
    }

    // ── Shared plumbing ─────────────────────────────────────────────────────

    private fun mediaPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.READ_MEDIA_AUDIO, Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    /** Runs [onResult] immediately when the permissions are held, else asks first. */
    private fun ensurePermissions(permissions: List<String>, onResult: (Boolean) -> Unit) {
        // Below Android 6 nothing is granted at runtime, so there is nothing to ask.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            onResult(true)
            return
        }

        val missing = mutableListOf<String>()
        for (permission in permissions) {
            if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                missing.add(permission)
            }
        }

        if (missing.isEmpty()) {
            onResult(true)
            return
        }

        pendingPermission = onResult
        requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST) return

        val callback = pendingPermission ?: return
        pendingPermission = null
        callback(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
    }

    private fun launchUri(uri: Uri): Boolean =
        startSafely(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    private fun startSafely(intent: Intent): Boolean = try {
        startActivity(intent)
        true
    } catch (error: ActivityNotFoundException) {
        false
    }

    private fun ok(vararg pairs: Pair<String, Any?>): Map<String, Any?> {
        val payload = mutableMapOf<String, Any?>("success" to true)
        for (pair in pairs) payload[pair.first] = pair.second
        return payload
    }

    private fun failure(message: String): Map<String, Any?> =
        mapOf("success" to false, "error" to message)
}
