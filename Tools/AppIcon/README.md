# AppIcon

The app icon is `WatchpostApp/Assets.xcassets/AppIcon.icon`, an Icon Composer file: a blue field
with a white viewfinder mark around a centred dot. It has Default, Dark and Tinted appearances.

`gen.py <output AppIcon.icon>` regenerates it from code (plain SVG paths, no strokes, so it renders
the same in Icon Composer and CoreSVG). Edit `gen.py`, regenerate into the asset catalog, then
preview with Icon Composer's `ictool`:

    python3 Tools/AppIcon/gen.py WatchpostApp/Assets.xcassets/AppIcon.icon
    ictool WatchpostApp/Assets.xcassets/AppIcon.icon --export-image --output-file /tmp/icon.png \
        --platform iOS --rendition Default --width 1024 --height 1024 --scale 1

`previews/` holds the renders of each appearance. The icon has no text, so it needs no
localisation.
