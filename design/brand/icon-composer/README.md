# Icon Composer handoff

`AppIcon.icon` is a real file-system package (directory containing `icon.json` and `Assets/*.svg`). The package is authored to the publicly observed Icon Composer structure; it has **not** been opened or compiled with Apple tools in this Linux environment.

## On macOS
1. Extract the ZIP in Finder (preserve the `AppIcon.icon` folder structure).
2. Open `AppIcon.icon` in Apple's [Icon Composer](https://developer.apple.com/icon-composer/). If a macOS version or app changes the undocumented manifest, make a new document in Icon Composer and drag the `import-layers-individually` folder into its layer list, in filename order.
3. Choose the macOS platform, background Harbor Navy `#10283F` (optionally gradient to `#071E30`). Set **Translucency off**, **Refraction low/none**, **Specular off/low**, **Shadow Natural 6-10%**, and preserve clean opaque colors.
4. Preview at 32 / 64 / 128 pixels, save as `AppIcon.icon`, and drag it into Xcode. Under app target **General > App Icons and Launch Screen**, set App Icon to `AppIcon`.

The layer files are scalable SVGs on 1024 x 1024 transparent canvases and contain genuine editable paths. They intentionally omit a squircle mask, because Icon Composer supplies the platform-specific enclosure.

Apple's documentation: https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
