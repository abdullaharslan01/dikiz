# dmgbuild ayarları: sürükle-bırak kurulum penceresi (Dikiz → Uygulamalar)
import os
app = defines.get("app", "../dist/Dikiz.app")  # noqa: F821
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines.get("bg", "dmg-bg.png")  # noqa: F821
format = "UDZO"
window_rect = ((200, 200), (660, 400))
icon_size = 128
text_size = 13
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_locations = {os.path.basename(app): (170, 200), "Applications": (490, 200)}
