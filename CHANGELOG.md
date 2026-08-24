# Changelog

## [1.0.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.11.0...hoplon-v1.0.0) (2026-08-24)


### ⚠ BREAKING CHANGES

* **memory:** upgrade to memory-rs v0.4.0, guardrail v0.14.1 ([#49](https://github.com/ArtemisMucaj/hoplon/issues/49))

### Features

* **memory:** upgrade to memory-rs v0.4.0, guardrail v0.14.1 ([#49](https://github.com/ArtemisMucaj/hoplon/issues/49)) ([ed2715f](https://github.com/ArtemisMucaj/hoplon/commit/ed2715fb2afeffc073fdf8647537a86c0ae52e4c))

## [0.11.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.10.1...hoplon-v0.11.0) (2026-08-24)


### Features

* **code:** remove button for codesearch LLM endpoints ([#43](https://github.com/ArtemisMucaj/hoplon/issues/43)) ([4857772](https://github.com/ArtemisMucaj/hoplon/commit/4857772a897e84caf2ce18f9abd2ab94841f7677)), closes [#42](https://github.com/ArtemisMucaj/hoplon/issues/42)

## [0.10.1](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.10.0...hoplon-v0.10.1) (2026-08-23)


### Bug Fixes

* **sign:** grant codesearch disable-library-validation ([#40](https://github.com/ArtemisMucaj/hoplon/issues/40)) ([3f35d8f](https://github.com/ArtemisMucaj/hoplon/commit/3f35d8fef32439baada0027c4598badc41dd366e))

## [0.10.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.9.0...hoplon-v0.10.0) (2026-08-23)


### Features

* **icon:** redraw the app icon as a round hoplon shield ([#38](https://github.com/ArtemisMucaj/hoplon/issues/38)) ([3b86dc6](https://github.com/ArtemisMucaj/hoplon/commit/3b86dc64747e2df712ee1789589eafe50b548911))

## [0.9.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.8.0...hoplon-v0.9.0) (2026-08-23)


### Features

* **guardrails:** pin v0.14.0 for the read-before-edit guard ([#36](https://github.com/ArtemisMucaj/hoplon/issues/36)) ([7b6d703](https://github.com/ArtemisMucaj/hoplon/commit/7b6d703465a21004b6e9821c55a093115eadbfbb))

## [0.8.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.7.0...hoplon-v0.8.0) (2026-08-22)


### Features

* **guardrails:** windowed metrics, a token calendar, and a providers pane ([#33](https://github.com/ArtemisMucaj/hoplon/issues/33)) ([23fe00a](https://github.com/ArtemisMucaj/hoplon/commit/23fe00a7dd258220eca83e4dfbf180c26cb3d246))

## [0.7.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.6.0...hoplon-v0.7.0) (2026-08-13)


### Features

* **code:** serve codesearch's MCP through the panoply proxy ([#27](https://github.com/ArtemisMucaj/hoplon/issues/27)) ([e7a80d8](https://github.com/ArtemisMucaj/hoplon/commit/e7a80d88b58656419a32f39c2c02a649d5041590))
* **skills:** install the memory-rs and codesearch agent skills ([#29](https://github.com/ArtemisMucaj/hoplon/issues/29)) ([18d6df9](https://github.com/ArtemisMucaj/hoplon/commit/18d6df9c4733b0ae6c728fb1c276ef80bfe4fa03))

## [0.6.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.5.0...hoplon-v0.6.0) (2026-08-11)


### Features

* **code:** create namespaces empty, and match Memory's UI to it ([#24](https://github.com/ArtemisMucaj/hoplon/issues/24)) ([8c46abe](https://github.com/ArtemisMucaj/hoplon/commit/8c46abe69b665f23f626ac8b1ba1e3337fff3dd0))

## [0.5.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.4.1...hoplon-v0.5.0) (2026-08-08)


### Features

* pick folders instead of typing project and repo names ([#22](https://github.com/ArtemisMucaj/hoplon/issues/22)) ([bdadea2](https://github.com/ArtemisMucaj/hoplon/commit/bdadea28c6ec1c47602481d1130f6ab0f3106a89))


### Bug Fixes

* simplify the Command Line pane ([#20](https://github.com/ArtemisMucaj/hoplon/issues/20)) ([2330df7](https://github.com/ArtemisMucaj/hoplon/commit/2330df74339453cf00b64beb5d9b113cab9b0b67))

## [0.4.1](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.4.0...hoplon-v0.4.1) (2026-08-08)


### Bug Fixes

* bump memory-rs pin to v0.3.0 ([#18](https://github.com/ArtemisMucaj/hoplon/issues/18)) ([0915b5c](https://github.com/ArtemisMucaj/hoplon/commit/0915b5cd6968537c9587b3a2dd21dd613d2f89ea))

## [0.4.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.3.1...hoplon-v0.4.0) (2026-08-07)


### Features

* ship the codesearch v2.0.1 pin ([#16](https://github.com/ArtemisMucaj/hoplon/issues/16)) ([3052b1d](https://github.com/ArtemisMucaj/hoplon/commit/3052b1d92f51df4d940d89ce78c6d8530ca0c3e5))

## [0.3.1](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.3.0...hoplon-v0.3.1) (2026-08-06)


### Bug Fixes

* list configured MCP servers in the sidebar, not just discovered ones ([#12](https://github.com/ArtemisMucaj/hoplon/issues/12)) ([a04ccc3](https://github.com/ArtemisMucaj/hoplon/commit/a04ccc32a4bcb4b44dcce2121b7271dd69843bbd))
* release 0.3.1 with the sidebar server-list fix ([#14](https://github.com/ArtemisMucaj/hoplon/issues/14)) ([b8dfb5a](https://github.com/ArtemisMucaj/hoplon/commit/b8dfb5a3e63e6566991375b008b3cada31bcb714))

## [0.3.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.2.2...hoplon-v0.3.0) (2026-08-06)


### Features

* install codesearch/memory-rs CLIs into ~/.local/bin ([#10](https://github.com/ArtemisMucaj/hoplon/issues/10)) ([e787097](https://github.com/ArtemisMucaj/hoplon/commit/e787097cf5f32836e0216b0a1911fe54d167506d))

## [0.2.2](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.2.1...hoplon-v0.2.2) (2026-08-06)


### Bug Fixes

* sign bundled panoply with library-validation disabled ([#8](https://github.com/ArtemisMucaj/hoplon/issues/8)) ([c7c3ddc](https://github.com/ArtemisMucaj/hoplon/commit/c7c3ddc35cb820864c0d1258a50e0bf608d10f49))

## [0.2.1](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.2.0...hoplon-v0.2.1) (2026-08-06)


### Bug Fixes

* release notarized macOS build with refreshed bundled binaries ([#6](https://github.com/ArtemisMucaj/hoplon/issues/6)) ([5af8ac7](https://github.com/ArtemisMucaj/hoplon/commit/5af8ac716fcee67a15d1f5e6719e3711e8b14685))

## [0.2.0](https://github.com/ArtemisMucaj/hoplon/compare/hoplon-v0.1.0...hoplon-v0.2.0) (2026-08-04)


### Features

* Hoplon, a native macOS control center for the local agent stack ([#1](https://github.com/ArtemisMucaj/hoplon/issues/1)) ([7d53e0b](https://github.com/ArtemisMucaj/hoplon/commit/7d53e0ba30c5a3506c9075bdd3a939d74744fab8))
