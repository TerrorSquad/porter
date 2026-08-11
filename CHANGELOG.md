# Changelog

## [1.1.0](https://github.com/TerrorSquad/porter/compare/v1.0.0...v1.1.0) (2026-08-11)


### Features

* **rust-sender:** fill the terminal with --multi=auto and a live grid toggle ([ddd904c](https://github.com/TerrorSquad/porter/commit/ddd904c9afc5f75f1432b37b67947e1d0ea72e92))
* **rust-sender:** report the grid change when [I] hides the sidebar ([a773738](https://github.com/TerrorSquad/porter/commit/a77373855f83395bfe625f1df15ca5bbad5ce13e))


### Bug Fixes

* **ci:** authenticate the tap push ([4200058](https://github.com/TerrorSquad/porter/commit/420005847284239bf7f0c4a14e8db14a1e80a794))
* **ci:** drop the redundant version line from the formula ([703701b](https://github.com/TerrorSquad/porter/commit/703701bad2d9458de13ab09991900805b43ede75))
* **rust-sender:** exclude the sidebar from the multi-QR width budget ([9fda0dc](https://github.com/TerrorSquad/porter/commit/9fda0dc47a59350ad637d413279e24607a175193))

## 1.0.0 (2026-08-10)


### ⚠ BREAKING CHANGES

* remove golang implementation

### Features

* add camera picker ([1169480](https://github.com/TerrorSquad/porter/commit/1169480e9c4665309d2f7c481564540c0de785b4))
* add initial files for the flutter project ([c852f18](https://github.com/TerrorSquad/porter/commit/c852f18722a60b6a901c8d46a6793a737a502e46))
* add serve target to Makefile for starting the porter HTTP server ([5ea1b3a](https://github.com/TerrorSquad/porter/commit/5ea1b3a91551e986143b739d867dacecd573ceb7))
* **flutter:** add fountain decoder with PRNG parity to nodejs encoder ([c226ea3](https://github.com/TerrorSquad/porter/commit/c226ea3561411241f1aa2bde7b4c9d9d1a8d14fc))
* **flutter:** detect a dead or stalled worker and warn before quitting ([39596ac](https://github.com/TerrorSquad/porter/commit/39596acb99089a0512f6534b8e372e7fddfe2109))
* **flutter:** enable Android build and run on-device ([7b08649](https://github.com/TerrorSquad/porter/commit/7b08649117d91663e33f5bb9275f19f7b339db35))
* **flutter:** make the Android receiver releasable ([a1dece1](https://github.com/TerrorSquad/porter/commit/a1dece1d0f0657c36e52a9b6cb47e3b4e82dd497))
* **flutter:** make the Android receiver releasable ([524a457](https://github.com/TerrorSquad/porter/commit/524a457e6aa8745c256543109c36960142dc5939))
* **flutter:** move receiver decoding off the UI thread, cap GF(2) fallback, debounce metadata, add resume ([2a84f78](https://github.com/TerrorSquad/porter/commit/2a84f780fd300948244f4ec8f489f979192c4ae1))
* **flutter:** resume fountain transfers instead of re-peeling from zero ([d69c151](https://github.com/TerrorSquad/porter/commit/d69c151c4eabea3d836070ca1a0d6a99719ed85d))
* **flutter:** show meaningful progress for fountain transfers ([a1e04dc](https://github.com/TerrorSquad/porter/commit/a1e04dc2daafac95a2cbd0445d59966a94177ab8))
* **flutter:** wire fountain transfers into Assembler and transfer UI ([22792a2](https://github.com/TerrorSquad/porter/commit/22792a21c125a3074a9c13be60460520433da40d))
* **golang:** add a server that listens to uploaded files ([4ac1e3d](https://github.com/TerrorSquad/porter/commit/4ac1e3d9c3418feb77fc6165bf4235104f0c2490))
* **golang:** copy built file to local/bin ([360bece](https://github.com/TerrorSquad/porter/commit/360bece5ff80bd32041fece300a2901252df9cec))
* implement join functionality for file transfers with manifest support ([4fee434](https://github.com/TerrorSquad/porter/commit/4fee4340677030afd8ec5e29531e0d409761f294))
* **nodejs:** 2x2 QR grid layout + auto-hiding info sidebar ([f9098a9](https://github.com/TerrorSquad/porter/commit/f9098a9421849532213c2df53d484debd4416afc))
* **nodejs:** add fountain coding (LT codes) encoder ([b401fd1](https://github.com/TerrorSquad/porter/commit/b401fd1b4985d74033d66aad35a18b072669414b))
* **nodejs:** add HTTP receiver server (porter serve) ([937c3e2](https://github.com/TerrorSquad/porter/commit/937c3e26210bda2c8e2be4a78d423c48c4997d73))
* **nodejs:** add join subcommand with SHA-256 verification (porter join) ([6e4e31f](https://github.com/TerrorSquad/porter/commit/6e4e31fb4afe5782c71f8106e29f3e076f4eb7ac))
* **nodejs:** decode fountain transfers in porter serve ([3caf4d4](https://github.com/TerrorSquad/porter/commit/3caf4d475de7de714152885b8b39dea16e5e0de1))
* **nodejs:** move to rollup ([2a2d461](https://github.com/TerrorSquad/porter/commit/2a2d461f6169b8b771baf5e4b49aeae4de1a13e5))
* **nodejs:** wire serve/join CLI dispatch with feature flags ([6aedd68](https://github.com/TerrorSquad/porter/commit/6aedd680a34c69e36c8ff86c2a011d221ec61a35))
* **porter_android:** add button to open the output directory ([f26cded](https://github.com/TerrorSquad/porter/commit/f26cded58cfff2a134fd9ab07819503966901c46))
* **porter_android:** add camera focus and frame-rate controls ([873e3bc](https://github.com/TerrorSquad/porter/commit/873e3bc471e82ac2384c85f4e3f6096c68903aa7))
* **porter_android:** add camera resolution picker incl. square presets ([b76959a](https://github.com/TerrorSquad/porter/commit/b76959a4f8a6926bebd7cab001b1e4d709e70ca9))
* **porter_android:** add macOS camera picker via patched mobile_scanner ([5f24056](https://github.com/TerrorSquad/porter/commit/5f24056d68577fcd10407301eb625c6cc2e3341b))
* **porter_android:** add multi-transfer cards screen ([6650e73](https://github.com/TerrorSquad/porter/commit/6650e739ca6b826cbf8fa9013af2df34867c63f5))
* **porter_android:** add persisted settings + Settings screen ([cca0ae7](https://github.com/TerrorSquad/porter/commit/cca0ae74521741ed9889bda3ea6ea600a49980a8))
* **porter_android:** add persistent Open button to transfer cards ([cf82149](https://github.com/TerrorSquad/porter/commit/cf821492af7ffebc5be9d87794657cb36fb79481))
* **porter_android:** add transfer-complete toast, auto-save, chunk grid, and zoom ([dbcaba7](https://github.com/TerrorSquad/porter/commit/dbcaba72dd8e86bab26e7e080186a1e52bade655))
* **porter_android:** limit frame-rate options by resolution ([030ca70](https://github.com/TerrorSquad/porter/commit/030ca7043098b49b74a5794a619b3ab60ecd91ea))
* **porter_android:** make save output directory configurable ([885fe36](https://github.com/TerrorSquad/porter/commit/885fe36d326c74c615bbb29bd33569005936e945))
* **porter_android:** persist chunks per-transfer and add open-folder button ([d27848a](https://github.com/TerrorSquad/porter/commit/d27848a4db6d3d4c0c2899452ab6ed4d9730045c))
* **porter_android:** relay scanned QR codes to a porter serve instance ([16fa625](https://github.com/TerrorSquad/porter/commit/16fa6253dfeca647754acf596038ff04c5710f56))
* **porter_android:** show live scans/sec in the HUD ([a0dfc00](https://github.com/TerrorSquad/porter/commit/a0dfc009562fac069178eec89d9d60f35664b282))
* **porter_android:** show transfer throughput and per-chunk detail ([09834e7](https://github.com/TerrorSquad/porter/commit/09834e7663f28fee94b53c230f1384f0764dfef8))
* prod-readiness pass + Rust sender (TUI, porter serve) ([#8](https://github.com/TerrorSquad/porter/issues/8)) ([65f06fa](https://github.com/TerrorSquad/porter/commit/65f06fab74c134b451cf19e08ad8c638d718b6a1))
* replace qrcode-terminal with qrcode-generator and add new features ([d2a2628](https://github.com/TerrorSquad/porter/commit/d2a26281f4d8c463d89e511ae3703bfbbbb47f7f))
* **rust-sender:** port porter join, superseding the TypeScript package ([0a274b0](https://github.com/TerrorSquad/porter/commit/0a274b024c72ee3a526c1bdd40fe60fb314592f7))
* **rust-sender:** warn before a very long transfer ([6b93c27](https://github.com/TerrorSquad/porter/commit/6b93c27d171a3323fa0d2d0678a69baa78355206))
* update chunk format to include ID and improve deduplication logic ([ebf7c37](https://github.com/TerrorSquad/porter/commit/ebf7c3731c6c3e9cf52fb5354e2d66abae6f1d21))
* **web:** add web-based QR receiver with camera, drop zone, relay and SHA-256 verification ([0364fdb](https://github.com/TerrorSquad/porter/commit/0364fdb2a9baa97d5508234b3577d004b81d27ad))


### Bug Fixes

* **deps:** add subprojects to workspace ([2ed87b2](https://github.com/TerrorSquad/porter/commit/2ed87b28a1818955be2e3925034010d3d4add269))
* **flutter:** duplicate scans of already-hydrated chunks must still surface the active transfer ([997c4b8](https://github.com/TerrorSquad/porter/commit/997c4b85971b24309819e506792cd0c20c6ce9c9))
* **flutter:** grant macOS bookmark entitlement for persisted output directory ([2a82799](https://github.com/TerrorSquad/porter/commit/2a82799ebedc43336c4caf5ff4ef8711604c64aa))
* **flutter:** hydrateAll must skip already-completed transfers ([8ff504c](https://github.com/TerrorSquad/porter/commit/8ff504ca4f62dc192cb96f31fd5c4db02d67dd0a))
* **flutter:** hydration crashed the receiver on real multi-thousand-chunk transfers ([a4b4919](https://github.com/TerrorSquad/porter/commit/a4b49197d7300d9dd492a547f6794edb52f5fa83))
* **flutter:** key fountain transfers on (id, K, blockSize), not id alone ([422646d](https://github.com/TerrorSquad/porter/commit/422646d18b253f0e5dd30853dff271e7ec270f89))
* **flutter:** report fountain progress, ETA and elapsed time honestly ([0cac6ea](https://github.com/TerrorSquad/porter/commit/0cac6ea2593aecc4870891959090102728e785e6))
* **flutter:** scale fountain progress to the blocks still missing ([71a2a1e](https://github.com/TerrorSquad/porter/commit/71a2a1e3750a61f23dc4eadd437478db7053d0ea))
* **flutter:** stop blinking the camera torch after every scan ([275242d](https://github.com/TerrorSquad/porter/commit/275242d78f3d780257ad247a5d8fc6f93d43241b))
* **flutter:** stop gitignoring the macOS xcconfig stubs ([cfa114f](https://github.com/TerrorSquad/porter/commit/cfa114f388512bccbd6cb964e00c527bf4f95244))
* **flutter:** stop the spill thrashing during the decode avalanche ([afeb372](https://github.com/TerrorSquad/porter/commit/afeb372854c11c5300e4668a61aad90761efb96b))
* **flutter:** track blocks on the progress bar, symbols behind it ([ce86810](https://github.com/TerrorSquad/porter/commit/ce8681057f7bc149be6c6bad9b2a39bb7e2c795c))
* **fountain:** make encoder usable on large files (no hang) ([c81ec4a](https://github.com/TerrorSquad/porter/commit/c81ec4a7b087cbe70cb5c2fdf26d3b4a9b7aba9a))
* **golang/receiver:** normalize QR format check to accept QRCode and qrcode variants ([582106b](https://github.com/TerrorSquad/porter/commit/582106bd040378f66d5ddac10ff82787589a2888))
* **nodejs:** cap multi-QR display to avoid sidebar overlapping codes ([0e9ce9f](https://github.com/TerrorSquad/porter/commit/0e9ce9fa3d54d4482affe2c5cd5d0949bc3304af))
* **nodejs:** eliminate periodic black flash in QR slideshow ([2206365](https://github.com/TerrorSquad/porter/commit/22063659a3ef9da10cb8da674983ef5aabcc0289))
* **porter_android:** add sandbox entitlements for relay and custom save dirs ([bfade53](https://github.com/TerrorSquad/porter/commit/bfade53b92f70cd67873e33d47e7a9a2da61127b))
* **porter_android:** avoid controllerNotAttached race on startup ([a300096](https://github.com/TerrorSquad/porter/commit/a300096fc312f2332d6c2be5939e04d98f469a38))
* **porter_android:** avoid crash when requesting unsupported frame rate ([5d9b831](https://github.com/TerrorSquad/porter/commit/5d9b831f813ac36c2feef93b2af38be22576f462))
* **porter_android:** crop preview to 1:1 for square resolution presets ([e83e39e](https://github.com/TerrorSquad/porter/commit/e83e39ed32eae8d3d95ba9ecf381ab19b2e4657f))
* **porter_android:** decay scans/sec when no new QR is detected ([7453abb](https://github.com/TerrorSquad/porter/commit/7453abb07221cf5356ee8b25f9112facc05e670d))
* **porter_android:** enable continuous autofocus on macOS ([3b421d6](https://github.com/TerrorSquad/porter/commit/3b421d68c39652afbfe84d7295a0a7951afb45e3))
* **porter_android:** enable tap-to-focus on macOS ([8e818f9](https://github.com/TerrorSquad/porter/commit/8e818f98fd47428087351b0cd9c77b4c27094158))
* **porter_android:** ignore torch errors during flash feedback ([ef6e542](https://github.com/TerrorSquad/porter/commit/ef6e54282b69793f40262d830f1c7d448f8884a0))
* **porter_android:** implement digital zoom for macOS via frame cropping ([724d875](https://github.com/TerrorSquad/porter/commit/724d87527350a9890a06104d4f16207931f237c9))
* **porter_android:** persist write access to the output directory on macOS ([66b6ad4](https://github.com/TerrorSquad/porter/commit/66b6ad4b3bfebf4d2f6d4c3900455a72b5957d85))
* **porter_android:** show save confirmation immediately with an Open action ([ebd8a75](https://github.com/TerrorSquad/porter/commit/ebd8a75ea068f67e34607d0f5a2cd06e96dfdd54))
* **renderer:** update sidebar display logic for slideshow mode ([501b7f3](https://github.com/TerrorSquad/porter/commit/501b7f3d1ac82399cd87158cf5b6fb9181a28152))
* **rust-sender:** avoid u32 overflow in the fountain degree table ([fa9f7b5](https://github.com/TerrorSquad/porter/commit/fa9f7b51752722a6fcec602a79c6adda14ba99c4))
* **rust-sender:** size QR payloads against a byte-mode encoding ([bdea42d](https://github.com/TerrorSquad/porter/commit/bdea42d2d951f8db728b8916e18b29db5b2d8bcd))
* typo on landing page ([da99321](https://github.com/TerrorSquad/porter/commit/da99321711f4d310291b9e01c5ec6df3f2611877))


### Performance Improvements

* **flutter:** make fountain peeling linear and bound its memory ([e2afead](https://github.com/TerrorSquad/porter/commit/e2afead16f630866acf0e49a8e7c897dc01a2fde))
* **flutter:** restrict scan to QR-only, default 1080p, infer sender cadence ([ca7c53c](https://github.com/TerrorSquad/porter/commit/ca7c53c70518b423c4f828178dcf3478f21cb90a))
* **nodejs:** batch terminal redraws into a single write ([fc58a27](https://github.com/TerrorSquad/porter/commit/fc58a277b2eced9ed284d8c0906ba83c32edc9f8))
* **porter_android:** remove artificial scan-rate cap on macOS ([cec26c8](https://github.com/TerrorSquad/porter/commit/cec26c877aaa6c3c903ac1ccd02d1c5576b578cc))
* **rust-sender:** lay multi-QR grids out width-first ([6e077aa](https://github.com/TerrorSquad/porter/commit/6e077aa6d617c36e9d93e712c9b0417cc8515bd1))


### Miscellaneous Chores

* remove golang implementation ([e60a8a3](https://github.com/TerrorSquad/porter/commit/e60a8a392bd995c5e4d7de90197c19b8367ba16f))
