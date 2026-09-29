# Third-party notices

The root noncommercial license covers only material identified as first-party
in `SOURCE_PROVENANCE.json`. It does not replace, restrict, or relicense rights
granted by upstream authors. Dependencies retain their own terms, including
any notice and source obligations when you distribute them or a binary.

## Bundled highlight.js and theme

These four files are unchanged third-party files:

- `GPTsora/highlight.min.js`
- `GPTsora/GPTsora/highlight.min.js`
- `GPTsora/atom-one-light.min.css`
- `GPTsora/GPTsora/atom-one-light.min.css`

They match the official highlight.js 11.9.0 distribution. The full
[highlight.js BSD 3-Clause license](third_party/highlight.js-LICENSE) carries
the original attribution to Ivan Sagalaev and its conditions and disclaimer.
Upstream: [highlight.js 11.9.0](https://github.com/highlightjs/highlight.js/tree/11.9.0).
An incomplete attribution string in the existing minified header is retained
unchanged; the complete upstream license accompanies it here.

Atom One Light is attributed to Daniel Gamage in the
[upstream theme source](third_party/highlight.js-atom-one-light.css.source),
which refers to [atom/one-light-syntax](https://github.com/atom/one-light-syntax).
Its original [MIT license](third_party/atom-one-light-MIT.txt), copyright
2016 GitHub Inc., is also included from commit
`d84579027410c576086dfca14d934c4bd74b0438`.

## Restored dependencies

Installed dependency directories are not part of this source snapshot.
Restore them using the committed npm, CocoaPods, SPM and Python dependency
records. Keep the notices supplied with the restored versions. In particular:

| Component | Source / license |
| --- | --- |
| GoogleWebRTC 1.1.32000 | CocoaPods / WebRTC BSD license and bundled third-party notices |
| RevenueCat purchases-ios 5.67.2 | [RevenueCat](https://github.com/RevenueCat/purchases-ios/tree/5.67.2), MIT and included dependency notices |
| React / React DOM | [React](https://github.com/facebook/react), MIT |
| Vite and Vite React plugin | [Vite](https://github.com/vitejs/vite), MIT |
| TypeScript | [TypeScript](https://github.com/microsoft/TypeScript), Apache-2.0 |
| LiveKit client and APIs | [LiveKit](https://github.com/livekit), Apache-2.0 and component notices |

Transitive dependencies and platform libraries may have additional licenses.
The above is a guide to the main components, not a replacement for their
complete distribution notices. Optional adapters do not transfer rights in
external CLIs, services, datasets, models, or separately obtained software.
