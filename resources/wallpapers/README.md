# Tonix Wallpapers

Place the following PNG wallpaper files in this directory before running the build:

- `tonix-circuit.png`   — Circuit board / tech aesthetic
- `tonix-sunset.png`    — Sunset theme (used as the default XFCE4 desktop wallpaper)
- `tonix-blue.png`      — Blue abstract
- `tonix-matrix.png`    — Matrix / digital rain aesthetic

These files are NOT included in the repository (they are listed in .gitignore).
Add your PNG files here and run `./tonix.sh build` to include them in the OS image.

All four wallpapers will be installed to `/usr/share/backgrounds/tonix/` in the built image.
Debian default wallpapers are removed during the build.
