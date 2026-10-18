# Viddeo brand assets

The SVG wordmarks and icons in `logo/` are built from original geometric shapes
in `build_logo.py`. PNG exports in `logo/png/` and the README banners in `readme/`
are committed so documentation and distribution can use them directly.

Regenerate the logos and local brand showcase with:

```sh
uv run --with shapely python brand/build_logo.py
```

PNG export also requires Google Chrome at its standard macOS application path.
Without Chrome, the script still writes the SVG files and showcase page.
The generated `brand/index.html` is ignored; edit `sheet.template.html` instead.

Regenerate the README banners with:

```sh
uv run --with pillow python brand/build_readme.py
```
