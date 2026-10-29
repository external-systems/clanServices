# Presentation

**Kubernetes cluster clanServices: one inventory, clusters you can prove.**

Click the slides and use the arrow keys, or
<a href="../slides/index.html" target="_blank">open them full screen in a new tab</a>
(press ++f++ there for full screen, ++esc++ for an overview of every slide).
++right++ moves to the next topic; ++down++ goes deeper into the current one.

<!-- Plain HTML links on purpose: the deck only exists inside the site
     after `nix build .#documentation`, and strict mode would fail the live
     preview on a Markdown link. URLs are relative to /presentation/. -->

<iframe src="../slides/index.html" title="Slide deck"
  style="width: 100%; aspect-ratio: 16 / 9; border: 0;"
  allowfullscreen></iframe>

??? info "For the presenter"
    Press ++s++ on the slides to open the speaker view with the talking
    points and a timer. The deck is built from
    `documentation/slides/slides.md`; preview it with
    `nix run .#serve-slides`.
