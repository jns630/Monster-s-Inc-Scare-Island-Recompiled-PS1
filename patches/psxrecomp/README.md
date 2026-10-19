# Framework patches

`scripts/build_from_disc.sh` applies every `*.patch` here to the `psxrecomp`
checkout (idempotent: an already-applied patch is skipped). Each one is a bug
fix in the framework at the pinned commit `155e269b`, worth sending upstream.

| Patch | Bug |
|---|---|
| `0001-pgxp-mod-not-reset-by-config.patch` | The built-in **PGXP Precision** mod (`psx.enhancement.pgxp`) arms geometry/texture correction during plugin activation, but `main.cpp` later re-applied the default-off `[video] geometry_correction` / `perspective_texturing` config unconditionally, silently turning the mod back off (`geom_correction` reported 0 hits). After the fix, config and env can only turn a correction *on*, so an enabled mod stays enabled. Verified on SCUS-94635: 0 → ~200k corrected vertices per session. |

Manual apply: `git -C psxrecomp apply ../patches/psxrecomp/<file>.patch`
