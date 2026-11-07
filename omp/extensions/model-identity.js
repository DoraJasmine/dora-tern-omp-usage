// Requires omp >= 18.18.0. Load with: omp --no-extensions -e /absolute/path/model-identity.js
// This is a main-session identity transport, not the model of a viewed subagent.
const WIDGET_KEY = "dora-omp-model-identity";
const IDENTITY_ROLE = "dora.omp.model-identity";

function createIdentityComponent(ctx) {
	const emptyRows = [];
	let previousSessionId;
	let previousProvider;
	let previousId;
	let node;

	return {
		render() {
			// No ANSI rows: the hidden native node is the entire transport.
			return emptyRows;
		},
		describe() {
			// Ordinary lifecycle contexts retain live model getters. Never snapshot
			// ctx.model or capture a provider-request context here.
			const model = ctx.models.current();
			const sessionId = ctx.sessionManager.getSessionId();
			const available = typeof sessionId === "string" && sessionId.length > 0
				&& typeof model?.provider === "string" && model.provider.length > 0
				&& typeof model?.id === "string" && model.id.length > 0;
			const provider = available ? model.provider : undefined;
			const id = available ? model.id : undefined;

			if (node && sessionId === previousSessionId && provider === previousProvider && id === previousId) {
				return node;
			}

			previousSessionId = sessionId;
			previousProvider = provider;
			previousId = id;
			node = {
				k: "text",
				p: {
					role: IDENTITY_ROLE,
					hidden: true,
					// Missing provider/id explicitly withdraws a previously available
					// identity; consumers must not reuse it or infer one from the chip.
					spans: [{ t: JSON.stringify({ version: 1, sessionId, scope: "main", provider, id }) }],
				},
			};
			return node;
		},
	};
}

export default function modelIdentity(pi) {
	let mountedUI;

	function clearWidget() {
		if (!mountedUI) return;
		mountedUI.setWidget(WIDGET_KEY, undefined);
		mountedUI = undefined;
	}

	function installWidget(_event, ctx) {
		// Factories are also loaded in spawned sessions. Never advertise their
		// identity as scope:main, or install native widgets in print/RPC mode.
		clearWidget();
		if (!ctx.hasUI || ctx.mode !== "tui" || ctx.agent.kind !== "main") return;

		ctx.ui.setWidget(WIDGET_KEY, () => createIdentityComponent(ctx), { placement: "belowEditor" });
		mountedUI = ctx.ui;
	}

	pi.on("session_start", installWidget);
	pi.on("session_switch", installWidget);
	pi.on("session_branch", installWidget);
	pi.on("session_tree", installWidget);
	pi.on("session_shutdown", clearWidget);
}
