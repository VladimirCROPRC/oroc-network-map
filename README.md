# oroc-network-map

Interactive network map with satellite and OpenStreetMap layers.

## Run locally

Serve the `dist` folder using a local HTTP server, for example:

```sh
python -m http.server 8000 --directory dist
```

Open http://localhost:8000.

## Mapbox

Copy `dist/mapbox-config.example.json` to `dist/mapbox-config.json` and insert your public Mapbox token. Restrict the token to your deployment domains. The real configuration is excluded from Git.

The repository includes the network layers used by the map. `.openai/hosting.json` records the existing Sites hosting project.
