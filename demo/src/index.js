var map = new maplibregl.Map({
    container: 'map', // container id
    style: '/style.json', // style URL
    hash: 'map',
    center: [0, 0], // starting position [lng, lat]
    zoom: 1 // starting zoom
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

function processMouseForPopup(e) {

  let entities = map.queryRenderedFeatures(e.point);
  let entity = entities.length && entities[0];

  if (!entity && !isPopupLocked) {
    activePopup?.remove();
    return;
  }

  if (activePopup && !activePopup.isOpen()) activePopup = null;

  if (!activePopup) {
    isPopupLocked = false;
    activePopup = new maplibregl.Popup({
      className: 'popup',
      closeButton: true,
      closeOnClick: false
    })
    .addTo(map);
  }
  if (!isPopupLocked) {
    let tags = entity.properties;
    let table = createElement('table')
      .setAttribute('class', 'tag-table')
      .replaceChildren(
        ...Object.keys(tags).sort().map(key => {
          let value = tags[key];
          return createElement('tr')
            .append(
              createElement('td')
                .append(key),
              createElement('td')
                .append(value)
            );
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
      let entity = entities.length && entities[0];

      if (entity) {
        processMouseForPopup(e);
        isPopupLocked = true;
      } else {
        activePopup.remove();
      }
    }
  }
}