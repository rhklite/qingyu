QINGYU 轻语 — app icon 4a
================================

COLOURS
  ground   #87C6CC   Aquatone Blue
  stroke   #123A42   ink teal
  dot      #E4A24C   amber  (listening state: #D9862F on light menu bars)
  dark alt #12414A   ground for dark-surface use, stroke becomes #87C6CC

FILES
  svg/qingyu-icon.svg            master, 1024 canvas, 824 squircle, transparent margin
  svg/qingyu-icon-small.svg      hand-hinted cut for 16-32px: content 87.5%, stroke 14/100,
                                 dot enlarged so the amber survives at ~2px
  svg/qingyu-icon-dark.svg       dark-ground variant
  svg/qingyu-mark.svg            mark only, transparent, 100 grid
  svg/qingyu-menubar.svg         monochrome template glyph (black + alpha)
  svg/qingyu-menubar-listening.svg

  Qingyu.iconset/                full macOS set, 16 through 512@2x
  png/                           loose PNGs at 1024 / 256 / 32 / 16
  menubar/                       16 and @2x, idle and listening

BEFORE YOU BUILD — RESTORE THE @2x NAMES
  This zip cannot carry "@" in filenames, so the retina files arrived as "-2x".
  Run rename-2x.sh inside the unzipped folder (or rename by hand):
      icon_16x16-2x.png   ->  icon_16x16@2x.png
      icon_32x32-2x.png   ->  icon_32x32@2x.png
      icon_128x128-2x.png ->  icon_128x128@2x.png
      icon_256x256-2x.png ->  icon_256x256@2x.png
      icon_512x512-2x.png ->  icon_512x512@2x.png
      menubar-16-2x.png   ->  menubar-16@2x.png
      menubar-listening-16-2x.png -> menubar-listening-16@2x.png
  iconutil will refuse the set otherwise.

BUILD .ICNS
  iconutil -c icns Qingyu.iconset

MENU BAR
  Use menubar-16 as an NSImage template (set isTemplate = true) so macOS tints it
  for light/dark automatically. For the listening state, draw the dot path in amber
  as a non-template image — the point of the two-tone mark is that the state change
  is one colour swap on one stroke, not a second glyph.

SMALL SIZES
  16 and 32 are cut from qingyu-icon-small.svg, not scaled from the master.
  Do not regenerate them by downscaling 1024 — the amber dot fills in.
