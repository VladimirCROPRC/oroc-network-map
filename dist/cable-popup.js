function cablePopup(feature,layerId) {
  const p=feature.properties||{},escape=value=>String(value??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
  const structure=(type,id)=>[type,id].filter(value=>value!==undefined&&value!==null&&value!=="").join(" · ");
  const rows=[["Proprietar",p.pr],["Status",p.st],["Tip",p.tp],["Structură capăt A",structure(p.ta,p.ia)],["Structură capăt Z",structure(p.tz,p.iz)],["Cabluri",p.cb]];
  if(layerId==="magistrale-backbone-cables"){
    const geometry=feature.geometry||{},lines=geometry.type==="LineString"?[geometry.coordinates]:geometry.type==="MultiLineString"?geometry.coordinates:[],radius=6371008.8;
    let meters=0;
    for(const line of lines)for(let i=1;i<line.length;i++){
      const [lon1,lat1]=line[i-1],[lon2,lat2]=line[i],toRadians=value=>value*Math.PI/180,dLat=toRadians(lat2-lat1),dLon=toRadians(lon2-lon1),a=Math.sin(dLat/2)**2+Math.cos(toRadians(lat1))*Math.cos(toRadians(lat2))*Math.sin(dLon/2)**2;
      meters+=2*radius*Math.atan2(Math.sqrt(a),Math.sqrt(1-a));
    }
    rows.push(["Lungime cablu",(meters/1000).toLocaleString("ro-RO",{minimumFractionDigits:2,maximumFractionDigits:2})+" km"]);
  }
  return '<div class="cable-popup-title">'+escape(p.n||"Cablu")+'</div><table class="cable-popup-table"><tbody>'+rows.map(([label,value])=>'<tr><th scope="row">'+escape(label)+'</th><td>'+escape(value===undefined||value===null||value===""?"—":value)+'</td></tr>').join("")+'</tbody></table>';
}
