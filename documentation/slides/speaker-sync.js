/* Keep the audience screen in step with the speaker view.
 *
 * reveal.js' speaker view (press S) moves its own preview first and tells
 * the main window afterwards, with a delay. Clicking through quickly makes
 * the audience screen lag, skip steps and jump back. This script runs inside
 * the speaker view's preview and sends every key press straight to the main
 * window instead; the preview then simply follows the main window.
 */
(function () {
	let audience = null;
	try {
		const q = location.search;
		if (/receiver/.test(q) && /postMessageEvents/.test(q)) audience = window.parent.opener.Reveal;
	} catch {
		return; // not the speaker preview, or another origin: leave reveal.js as is
	}
	if (!audience) return;

	// Keys pressed anywhere in the speaker window reach the preview as a
	// "triggerKey" message; keys pressed inside the preview are plain keydowns.
	window.addEventListener(
		"message",
		(e) => {
			let data;
			try {
				data = JSON.parse(e.data);
			} catch {
				return;
			}
			if (data && data.method === "triggerKey") {
				e.stopImmediatePropagation();
				audience.triggerKey(data.args[0]);
			}
		},
		true,
	);
	window.addEventListener(
		"keydown",
		(e) => {
			e.preventDefault();
			e.stopImmediatePropagation();
			audience.triggerKey(e.keyCode);
		},
		true,
	);
})();
