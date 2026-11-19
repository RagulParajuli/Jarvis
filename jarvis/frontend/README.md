# Jarvis web client

The browser client for Jarvis, built with Next.js, [Agents UI](https://livekit.io/ui)
components, and the [LiveKit JavaScript SDK](https://github.com/livekit/client-sdk-js).
It shows the same HUD as the Flutter app and connects to the deployed agent
without a terminal.

### Features

- Real-time voice interaction with the Jarvis agent
- Camera video streaming and screen sharing
- Jarvis HUD with a radial audio visualizer
- Virtual avatar integration
- Hands-free auto-connect before the user presses anything
- Customizable branding, colors, and UI text

## Getting started

```bash
pnpm install
pnpm dev
```

Then open http://localhost:3000 in your browser.

## Connect to your agent

Copy `.env.example` to `.env.local` and fill in your LiveKit project credentials:

```env
LIVEKIT_URL=wss://<project-subdomain>.livekit.cloud
LIVEKIT_API_KEY=<your_api_key>
LIVEKIT_API_SECRET=<your_api_secret>
AGENT_NAME=my-agent
JARVIS_ACCESS_CODE=<a long random code>
```

`AGENT_NAME` is the dispatch name in `src/agent.py`; it makes joining a room
start that agent. Leave it blank for automatic dispatch.

`JARVIS_ACCESS_CODE` is required by the included token route. Clients send it in
the `X-Jarvis-Access-Code` header; a missing code and a wrong code get the same
`401` answer, and repeated failures from one address get `429`.

The page gets its token from [`app/api/token/route.ts`](./app/api/token/route.ts),
or from the LiveKit development token server if `LIVEKIT_TOKEN_SERVER_ID` is set.

## Token generation in production

In production, you will be responsible for developing a solution to [generate tokens for your users](https://docs.livekit.io/home/server/generating-tokens/) that integrates with your authentication system. Add an authentication layer to [`app/api/token/route.ts`](./app/api/token/route.ts), or point `tokenEndpoint` in [`app/page.tsx`](./app/page.tsx) at your own token server.

### Required before exposing the endpoint

- **A rate-limit store.** Failed access-code attempts are counted per client
  address. Set `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN` (Upstash
  Redis, free tier is enough) so every Vercel instance shares the same counters.
  Without them the route falls back to per-instance memory, which a client can
  bypass by reaching another instance, so treat that fallback as development
  only. The route calls Upstash's REST API directly; there is no extra npm
  dependency.
- **A strong access code.** `JARVIS_ACCESS_CODE` should be long and random
  (32+ characters). It is compared in constant time and never logged.

### Token settings

| Variable                         | Default | Meaning                                                                                                    |
| -------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------- |
| `LIVEKIT_TOKEN_TTL`              | `15m`   | Token lifetime. Accepts `30s`, `15m` or `1h`; values outside 1 minute to 6 hours fall back to the default. |
| `AUTH_RATE_LIMIT_MAX_FAILURES`   | `10`    | Failed codes allowed per address per window.                                                               |
| `AUTH_RATE_LIMIT_WINDOW_SECONDS` | `900`   | Length of that window, 60-86400 seconds.                                                                   |

The route validates every client-controlled field. `room_name` and
`participant_identity` are restricted to a safe character set and length,
`participant_metadata` must be a JSON object of at most 2 KB, and `room_config`
may only request this deployment's own agent. Unknown room settings are
rejected rather than passed through.

> [!WARNING]
> `ALLOW_PUBLIC_TOKEN=true` disables access-code authentication entirely: anyone
> who knows the URL can mint a room token and talk to your agent, on your
> bill. It is off by default, must never be used for a normal or public
> deployment, and exists only for a throwaway local experiment.

## Trusted device endpoints

| Route                             | Purpose                                                     | Authentication   |
| --------------------------------- | ----------------------------------------------------------- | ---------------- |
| `POST /api/device/pairing`        | Issue a one-time pairing code                               | access code      |
| `POST /api/device/pairing/redeem` | Register a device and its ES256 key with a pairing code     | the pairing code |
| `POST /api/device/challenge`      | Issue a short-lived one-time challenge for a trusted device | access code      |

The plaintext challenge is returned once and stored only as a SHA-256 hash,
bound to the device, the account and the `jarvis-token-api-v1` audience. The
device signs that audience-bound payload and submits it to `POST /api/token` as
`device_assertion: { device_id, nonce, issued_at_ms, signature }`. The challenge
is consumed atomically before a token is minted; an invalid assertion is always
rejected rather than falling back to the access code. The access code stays as
a temporary fallback while clients are migrated.

## Database (server-only)

Jarvis stores devices, history and memories in PostgreSQL; the schema, its tests
and the Supabase setup workflow live in [`../supabase/`](../supabase/). The web
app reaches the database only from the server, through
[`lib/database.ts`](./lib/database.ts).

To create a development project, collect its connection strings, apply the
migrations and verify the result, follow
[`../supabase/README.md`](../supabase/README.md#supabase-development-project).
That page is the single source of truth; this section only covers what the app
needs at runtime.

### Environment

| Variable           | Used by                                       | Meaning                                                                                                                                            |
| ------------------ | --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DATABASE_URL`     | this app                                      | Pooled PostgreSQL connection string (Supabase Supavisor, transaction mode, port `6543`) with TLS.                                                  |
| `DATABASE_CA_CERT` | this app                                      | Optional PEM CA certificate for remote TLS verification (for example Supabase Root 2021 on Vercel). Server-only; never prefix with `NEXT_PUBLIC_`. |
| `DIRECT_URL`       | Supabase CLI, migrations and `pnpm db:verify` | Direct connection for `supabase db push`, the SQL test runner and the read-only setup checks. App code never reads it.                             |

`DATABASE_URL` must never become `NEXT_PUBLIC_DATABASE_URL`: every `NEXT_PUBLIC_`
value is inlined into the browser bundle. `lib/database.ts` reports a
configuration error if it finds such a variable, and the build fails if a client
component imports the module, because the module starts with
`import 'server-only'`.

`DATABASE_CA_CERT`, when set, must contain a full PEM certificate including the
`BEGIN CERTIFICATE` and `END CERTIFICATE` lines. It is read only by server code
and is added as a trusted root for remote PostgreSQL TLS; verification stays
enabled. Set it on Vercel if the runtime does not already trust Supabase Root
2021 and the connection fails with `SELF_SIGNED_CERT_IN_CHAIN`. Leave it unset
for local databases or when the platform trust store already works. Never
create a `NEXT_PUBLIC_DATABASE_CA_CERT` variant.

### Local setup

1. Get a database with the schema applied. Either:
   - start a throwaway container (`./supabase/scripts/test-db.sh`), or
   - create a **development** Supabase project and push the migrations to it,
     following [`../supabase/README.md`](../supabase/README.md#supabase-development-project).

   Never point either option at production.

2. Set the connection string in `.env.local`:
   ```env
   DATABASE_URL=postgresql://postgres@localhost:5432/jarvis_test
   # Supabase project: the pooled 6543 string, plus the direct 5432 one for tooling
   DIRECT_URL=postgresql://postgres@localhost:5432/jarvis_test
   ```
   Loopback hosts connect without TLS. Every other host must present a
   certificate that verifies against the system trust store, or against
   `DATABASE_CA_CERT` when that variable is set.
3. Verify the setup without changing anything:
   ```bash
   pnpm db:verify --development
   ```
   This is read-only: it checks both endpoints, the migration history, the
   schema objects, RLS and the privilege lockdown, and prints only a variable
   name, endpoint kind, port, database name and TLS state — never a host or a
   password. The `--development` flag is required, and the script loads
   `.env.local` for you. Exit codes: `0` usable, `1` a check failed, `2` the
   flag was missing.
4. Run `pnpm dev`.

### Usage

```ts
import { getDatabase } from '@/lib/database';

const db = getDatabase();

const user = await db.queryRow<{ id: string }>('select id from jarvis.users limit 1');
const messages = await db.queryRows<{ id: number }>(
  'select id from jarvis.messages where user_id = $1',
  [userId]
);
const reachable = await db.ping();
```

Always pass values as parameters (`$1`, `$2`), never by interpolating them into
the SQL string. The generics are compile-time only: rows arrive exactly as the
driver returns them, so keep the types in step with the S4.1 schema.

### Pooling on Vercel

- One `pg.Pool` per process, cached on `globalThis` so warm invocations and hot
  reloads reuse it. Never create a pool per request, and never call
  `pool.end()` from a request; `closeDatabasePool()` is for tests and graceful
  shutdown.
- `max` is 3 (`DATABASE_POOL_MAX`). Supabase's pooler multiplexes those small
  per-instance pools onto a limited number of real connections.
- Idle clients close after 10 seconds and a connect attempt times out after 10
  seconds, so an unreachable database fails a request instead of hanging it, and
  short-lived processes can exit.
- Use the **pooled** connection string (port `6543`, transaction mode); the
  direct port is for migrations.
- If the pooler's certificate chain is not trusted by Vercel's runtime, set the
  server-only `DATABASE_CA_CERT` to the PEM CA certificate. This adds a trusted
  root; it does not set `rejectUnauthorized: false` or disable TLS.

### Error handling

Failures are wrapped in `DatabaseQueryError`, which exposes a SQLSTATE and
identifier names (constraint, table, column) only. `safeDatabaseError()` is the
only form that is safe to log: PostgreSQL messages can quote row values and
connection errors can quote the host. The connection string, its password and
query parameters are never logged, returned, or attached as an error `cause`.

### Tests

```bash
pnpm test
```

[`test/database.test.ts`](./test/database.test.ts) needs no database: it injects
a fake query executor and covers row mapping, error redaction, `ping()`, pool
settings, and the rule that no client component may import the module or name
`DATABASE_URL`. `test/database-setup.test.ts` and `test/database-checks.test.ts`
cover the verification script the same way, including that no check ever prints
a host, password or URL. `test/supabase-migrations.test.ts` guards the migration
files themselves: filename order, one transaction per file, required objects,
and the absence of connection strings. The test script runs Node with
`--conditions=react-server` because `server-only` throws under Node's default
condition; that condition is also what the production build uses.

## Project structure

This starter uses the [Agents UI](https://livekit.io/ui) components for core UI elements like media controls, audio visualizers, chat transcripts, and providing session data. Shadcn installs components into `components/` folder so you can customize them like any other local component.

```
agent-starter-react/
├── app/
│   ├── api/
├── components/
│   ├── agents-ui/     - Agents UI components
│   ├── app/           - App-specific components
│   ├── ui/            - Primitive shadcn/ui components
├── fonts/
├── hooks/
├── lib/
├── public/
└── package.json
```

Business logic lives within the `components/app` folder. It's here where the application's state and behavior is managed and the various Shadcn UI components are composed together.

| File                  | Description                                                                                                                                           |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `session-view.tsx`    | Initializes the application, and LiveKit session. Renders the view controller and session UI including chat transcript, media tiles, and control bar. |
| `view-controller.tsx` | Manages the transitions between the welcome and session views based on the LiveKit session state.                                                     |
| `welcome-view.tsx`    | Renders the welcome UI when the LiveKit session is not connected.                                                                                     |
| `chat-transcript.tsx` | Manages the chat transcript transitions.                                                                                                              |
| `tile-layout.tsx`     | Manages the layout and transition of media tiles in various application states.                                                                       |

### Component usage

Most Agents UI components require access to a LiveKit session object for access to values like agent state or audio tracks. A Session object can be created from a [TokenSource](/reference/client-sdk-js/variables/TokenSource.html), and provided by wrapping the component in an [AgentSessionProvider](/reference/components/shadcn/component/agent-session-provider).

See [`components/app/app.tsx`](./components/app/app.tsx) for an example of how this is done in this app.

### Customizing components

Agents UI components, like most Shadcn components, take as many primitive attributes as possible. For example, the [AgentControlBar](/reference/components/shadcn/component/agent-control-bar/page.mdoc) component extends `HTMLAttributes<HTMLDivElement>`, so you can pass any props that a div supports. This makes it easy to extend the component with your own styles or functionality.

You can edit any Agents UI component's source code in the `components/agents-ui` directory. For style changes, we recommend passing in tailwind classes to override the default styles. Take a look at the source code to get a sense of how to override a component's default styles.

### Updating components

To update the Agents UI components to the latest publication, run the following command:

```bash
pnpm shadcn:install
```

> [!NOTE]
> The CLI will ask before overwriting any modified files so you can avoid losing any customizations you might have made.

### Installing components

```bash
pnpm dlx shadcn@latest add @agents-ui/{component-name-a} @agents-ui/{component-name-b}
```

## Configuration

This starter is designed to be flexible so you can adapt it to your specific agent use case. Branding, feature toggles, and UI text are set directly in the components that use them — see [`app/layout.tsx`](./app/layout.tsx) for branding (logo, colors, page title/description) and [`components/app/view-controller.tsx`](./components/app/view-controller.tsx) for feature toggles. Video and screen share input follow the connected agent; override `isVideoInputSupported` in [`app/page.tsx`](./app/page.tsx) to force them on or off.

#### Audio visualizer

The Jarvis HUD renders `AgentAudioVisualizerRadial` in [`components/app/hud-session-view.tsx`](./components/app/hud-session-view.tsx); the track control uses `AgentAudioVisualizerBar`. There are no runtime visualizer presets — edit those components to adjust their appearance.

## Contributing

This template is open source and we welcome contributions! Please open a PR or issue through GitHub, and don't forget to join us in the [LiveKit Community Slack](https://livekit.io/join-slack)!
