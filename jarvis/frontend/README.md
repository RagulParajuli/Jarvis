# Jarvis web client

The browser client for Jarvis, built with Next.js, [Agents UI](https://livekit.io/ui)
components, and the [LiveKit JavaScript SDK](https://github.com/livekit/client-sdk-js).
It shows the same HUD as the Flutter app and connects to the deployed agent
without a terminal.

### Features

- Real-time voice interaction with the Jarvis agent
- Camera video streaming and screen sharing
- Multiple audio visualizer styles (`bar`, `grid`, `radial`, `wave`, `aura`)
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
```

`AGENT_NAME` is the dispatch name in `src/agent.py`; it makes joining a room
start that agent. Leave it blank for automatic dispatch.

The page gets its token from [`app/api/token/route.ts`](./app/api/token/route.ts),
or from the LiveKit development token server if `LIVEKIT_TOKEN_SERVER_ID` is set.

## Token generation in production

In production, you will be responsible for developing a solution to [generate tokens for your users](https://docs.livekit.io/home/server/generating-tokens/) that integrates with your authentication system. Add an authentication layer to [`app/api/token/route.ts`](./app/api/token/route.ts), or point `tokenEndpoint` in [`app/page.tsx`](./app/page.tsx) at your own token server.

The included route requires `JARVIS_ACCESS_CODE` by default. For a private
deployment where the phone should connect without a code prompt, set
`ALLOW_PUBLIC_TOKEN=true`; anyone who finds the URL can then mint a short-lived
token and talk to the agent. Add authentication before making the site public.

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

This starter is designed to be flexible so you can adapt it to your specific agent use case. Branding, feature toggles, and UI text are set directly in the components that use them — see [`app/layout.tsx`](./app/layout.tsx) for branding (logo, colors, page title/description) and [`components/app/view-controller.tsx`](./components/app/view-controller.tsx) for feature toggles and the audio visualizer. Video and screen share input follow the connected agent; override `isVideoInputSupported` in [`app/page.tsx`](./app/page.tsx) to force them on or off.

#### Audio visualizer presets

Set `audioVisualizerType` in [`components/app/view-controller.tsx`](./components/app/view-controller.tsx) to switch visualizer styles:

- `bar` (default): vertical bars with optional `audioVisualizerBarCount`
- `grid`: dot grid with `audioVisualizerGridRowCount` and `audioVisualizerGridColumnCount`
- `radial`: circular bars with `audioVisualizerRadialBarCount` and `audioVisualizerRadialRadius`
- `wave`: oscilloscope-style wave with `audioVisualizerWaveLineWidth`
- `aura`: shader-based aura with `audioVisualizerAuraColorShift`

Use `audioVisualizerColor` to set a shared accent color across all visualizer modes.

## Contributing

This template is open source and we welcome contributions! Please open a PR or issue through GitHub, and don't forget to join us in the [LiveKit Community Slack](https://livekit.io/join-slack)!
