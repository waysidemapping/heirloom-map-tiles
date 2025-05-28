var map = new maplibregl.Map({
    container: 'map',
    style: '/style.json',
    hash: 'map',
    minZoom: 5,
    center: [0, 0],
    zoom: 5
});

map
  .addControl(new maplibregl.NavigationControl({
    visualizePitch: true
  }))
  .addControl(new maplibregl.GeolocateControl({
      positionOptions: {
          enableHighAccuracy: true
      },
      trackUserLocation: true
  }))
  .addControl(new maplibregl.ScaleControl({
      maxWidth: 150,
      unit: 'imperial'
  }), "bottom-left");

map.on('mousemove', didMouseMoveMap);
map.on('click', didClickMap);


let activePopup;

let isPopupLocked = false;

function didMouseMoveMap(e) {

  let entities = map.queryRenderedFeatures(e.point);
  let entity = entities.length && entities[0];
  // Change the cursor style as a UI indicator
  map.getCanvas().style.cursor = entity ? 'pointer' : '';
  
  processMouseForPopup(e);
}

let osmTypeName = {
  'n': 'node',
  'w': 'way',
  'r': 'relation'
};

function processMouseForPopup(e) {

  let entities = map.queryRenderedFeatures(e.point).filter(entity => !entity.layer.id.includes('-label'));

  if (!entities.length && !isPopupLocked) {
    activePopup?.remove();
    return;
  }

  if (activePopup && !activePopup.isOpen()) activePopup = null;

  if (!activePopup) {
    isPopupLocked = false;
    activePopup = new maplibregl.Popup({
      className: 'popup',
      closeButton: true,
      closeOnClick: false,
      maxWidth: '300px'
    })
    .addTo(map);
  }
  if (!isPopupLocked) {

    let table = createElement('table')
      .setAttribute('class', 'tag-table')
      .replaceChildren(
        ...entities.flatMap(entity => {
          let tags = Object.assign({}, entity.properties);
          let osmId = tags.osm_id;
          let osmType = tags.osm_type;
          let area = tags.area_3857 ? ' · ' + new Intl.NumberFormat('en-US').format(Math.round(tags.area_3857)) + ' m²' : '';
          delete tags.area_3857;
          delete tags.osm_id;
          delete tags.osm_type;
          return [
            createElement('tr')
              .append(
                createElement('td')
                  .setAttribute('class', 'entity-header')
                  .setAttribute('colspan', '2')
                  .replaceChildren(
                    createElement('span')
                      .append(entity.sourceLayer),
                    createElement('span')
                      .append(area),
                    (osmId && osmType) ? createElement('a')
                    .setAttribute('target', '_blank')
                    .setAttribute('href', `https://openstreetmap.org/${osmTypeName[osmType]}/${osmId}`)
                    .append(osmType + '/' + osmId) : ''
                  )
              ),
            ...Object.keys(tags).sort().map(key => {
              let value = tags[key];
              let href = externalLinkForValue(key, value, tags);
              let valElement = href ? createElement('a')
                  .setAttribute('target', '_blank')
                  .setAttribute('rel', 'nofollow')
                  .setAttribute('href', href)
                  .append(value) : value;
          
              return createElement('tr')
                .append(
                  createElement('td')
                    .append(
                      createElement('a')
                        .setAttribute('target', '_blank')
                        .setAttribute('href', `https://wiki.openstreetmap.org/wiki/Key:${key}`)
                        .append(key)
                    ),
                  createElement('td')
                    .append(valElement)
                );
            })
          ]
        })
      );

    let coordinates = e.lngLat;
    // Ensure that if the map is zoomed out such that multiple
    // copies of the feature are visible, the popup appears
    // over the copy being pointed to.
    while (Math.abs(e.lngLat.lng - coordinates[0]) > 180) {
      coordinates[0] += e.lngLat.lng > coordinates[0] ? 360 : -360;
    }

    activePopup.setLngLat(coordinates)
      .setDOMContent(table); 
  }
}

function didClickMap(e) {
  if (activePopup && activePopup.isOpen()) {
    if (!isPopupLocked) {
      let classList = activePopup.getElement().classList;
      if (!classList.contains('locked')) classList.add('locked');
      isPopupLocked = true;
    } else {
      isPopupLocked = false;

      let entities = map.queryRenderedFeatures(e.point);

      if (entities.length) {
        processMouseForPopup(e);
        isPopupLocked = true;
      } else {
        activePopup.remove();
      }
    }
  }
}

const urlRegex = /^https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)$/i;
const qidRegex = /^Q\d+$/;
const wikipediaRegex = /^(.+):(.+)$/;

function externalLinkForValue(key, value, tags) {
  if (urlRegex.test(value)) {
    return value;
  } else if ((key === 'wikidata' || key.endsWith(':wikidata')) && qidRegex.test(value)) {
    return `https://www.wikidata.org/wiki/${value}`;
  } else if ((key === 'wikipedia' || key.endsWith(':wikipedia')) && wikipediaRegex.test(value)) {
    let results = wikipediaRegex.exec(value);
    return `https://${results[1]}.wikipedia.org/wiki/${results[2]}`;
  }
  return null;
}