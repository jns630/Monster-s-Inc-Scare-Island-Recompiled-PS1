/*
 * Game-owned trusted plugins for Monsters, Inc. Recompiled.
 *
 * The framework keeps widescreen mod-owned on PSX (a stale settings.toml must
 * not be able to engage it), so the title opts in here. The manifest that
 * selects these plugins lives in mods/preloaded/packages/monstersinc.enhancements.
 */
#include "mod_plugins.h"

#include <string.h>

#define PKG "monstersinc.enhancements"

static void monstersinc_widescreen_activate(void) {
    char aspect[16] = "";
    (void)psx_mod_option_value(PKG, "widescreen", "aspect", aspect, sizeof aspect);
    if (strcmp(aspect, "21:9") == 0)
        (void)psx_mod_set_fixed_display_aspect(21u, 9u);
    else
        (void)psx_mod_set_fixed_display_aspect(16u, 9u);
}

PSX_MOD_CONSTRUCTOR(monstersinc_register_plugins) {
    (void)psx_mod_register_activation_plugin("monstersinc.widescreen",
                                             monstersinc_widescreen_activate);
}
