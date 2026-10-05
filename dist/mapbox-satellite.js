async function addMapboxSatellite(map, layerControl, onError, previousBase) {
  try {
    const response = await fetch("mapbox-config.json", {cache:"no-store"});
    if (!response.ok) throw new Error();
    const config = await response.json();
    if (!config.accessToken?.startsWith("pk.")) return;
    const attribution = '© <a href="https://www.mapbox.com/about/maps/">Mapbox</a> © <a href="https://www.maxar.com/">Maxar</a> <a href="https://apps.mapbox.com/feedback/" target="_blank" rel="noopener">Improve this map</a>';
    const satellite = L.tileLayer("https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}.jpg90?access_token=" + encodeURIComponent(config.accessToken), {
      maxNativeZoom:19,maxZoom:20,tileSize:256,updateWhenIdle:true,keepBuffer:1,attribution
    });
    const logo = L.control({position:"bottomright"});
    logo.onAdd = () => {
      const link = L.DomUtil.create("a");
      link.href = "https://www.mapbox.com/";
      link.target = "_blank"; link.rel = "noopener noreferrer";
      link.innerHTML = '<img src="mapbox-logo.svg" alt="Mapbox" width="88" height="23">';
      L.DomEvent.disableClickPropagation(link);
      return link;
    };
    satellite.on("add", () => logo.addTo(map));
    satellite.on("remove", () => logo.remove());
    let failed = false;
    satellite.on("tileerror", () => {
      if (failed) return;
      failed = true;
      map.removeLayer(satellite);
      previousBase.addTo(map);
      onError("Imaginile Mapbox nu au putut fi încărcate. Alege Satelit Esri sau OpenStreetMap.");
    });
    layerControl.addBaseLayer(satellite,"Mapbox Satellite");

  } catch { onError("Mapbox nu este disponibil. Verifică tokenul și domeniile permise."); }
}
