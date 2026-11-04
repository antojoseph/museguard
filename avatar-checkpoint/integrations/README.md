# Saved integrations

`dependencies.json` records the installed versions and the model configuration at the checkpoint. The current setup uses Blender 5.2.4 LTS Release Candidate, Pi 1.4.0, MCP for Blender addon 1.8 / protocol 15, and the `mcp-for-blender` Python package 2.2.6.

`blender/blender_mcp.py` is an unchanged copy of the installed addon, whose source credits Siddharth Ahuja. Its original header and notices are retained. It is preserved here so the existing local connection can be restored; it is not authored by this project.

`config/pi/extensions/baseten-image-limit.ts` is the configured image-limit extension. `config/pi/` also holds non-secret settings, model, and MCP templates. The model template references the `BASETEN_API_KEY` environment variable. The resume launcher can instead reference the existing private helper on this Mac without copying its contents.

No authentication files, API keys, token values, or raw Pi conversations are included. Third-party executable downloads and package caches remain outside the Git checkpoint. The pinned Pi release URL and its observed archive digest are recorded for restoration if the local installation is lost.
