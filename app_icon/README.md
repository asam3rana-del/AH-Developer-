# Hanna POS — app icon

Asal design: Hanna Software Series › App Icons › `HannaPOS` (navy `#0B2545`, safed H, peela `#F5B841` barcode).

- `hanna_pos_icon.svg` — poora icon (master). `hanna_pos_foreground.svg` — bina background (Android adaptive).
- `android/` — CI (`build.yml` › Set Android app icon) `android/app/src/main/res/` mein copy karta hai.
- `ios/icon_<px>.png` — CI AppIcon.appiconset ki har PNG ko usi size se badalta hai (alpha nahi).
- Windows: `../windows_assets/app_icon.ico` (16–256 px).
- Shop ka logo (`assets/images/logo.png`, slip/PDF par) alag hai — wo nahi badla.

Icon badalna ho to SVG badal kar ye PNG/ICO dobara banayein (rsvg-convert + ImageMagick).
