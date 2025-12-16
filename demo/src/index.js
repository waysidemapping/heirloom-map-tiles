import {beefsteakProtocolFunction} from './beefsteak-protocol.js';

var map;

const sidebar = document.getElementById('sidebar');

window.addEventListener('load', async function () {

  const styleJson = await fetch('/style/beefsteak-demo-style.json').then(response => response.json());

  map = new maplibregl.Map({
    container: 'map',
    style: styleJson,
    hash: 'map',
    minZoom: 0,
    center: [0, 0],
    zoom: 5
  });

  const beefsteakEndpoint = styleJson.sources.beefsteak.url;
  const beefsteakEndpointPrefix = /(.*\/\/.*\/)/.exec(beefsteakEndpoint)[1];

  console.log(beefsteakEndpointPrefix);

  maplibregl.addProtocol('beefsteak', beefsteakProtocolFunction);
  map.setTransformRequest((url, resourceType) => {
      if (url.startsWith(beefsteakEndpointPrefix) && resourceType === 'Tile') {
          return { url: 'beefsteak://' + url };
      }
      return undefined;
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
})

let isPopupLocked = false;

let queryOpts = {layers:['area-target', 'line-target', 'point-label']};

function didMouseMoveMap(e) {

  let entities = map.queryRenderedFeatures(e.point, queryOpts);
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

function idToOsmType(id) {
  switch (id % 10) {
    case 1: return 'n';
    case 2: return 'w';
    case 3: return 'r';
    default: return null;
  }
}

function processMouseForPopup(e) {

  let entities = map.queryRenderedFeatures(e.point, queryOpts);

  if (!entities.length && !isPopupLocked) {
    sidebar.replaceChildren();
    return;
  }

  if (!isPopupLocked) {

    let table = createElement('table')
      .setAttribute('class', 'tag-table')
      .replaceChildren(
        ...entities.flatMap(entity => {
          let tags = Object.assign({}, entity.properties);
          let osmId = Math.floor(entity.id / 10);
          let osmType = idToOsmType(entity.id);
          // let area = tags.area_3857 ? ' · ' + new Intl.NumberFormat('en-US').format(Math.round(tags.area_3857)) + ' m²' : '';
          // delete tags.area_3857;
          return [
            createElement('tr')
              .append(
                createElement('td')
                  .setAttribute('class', 'entity-header')
                  .setAttribute('colspan', '2')
                  .replaceChildren(
                    createElement('span')
                      .append(entity.sourceLayer),
                    // createElement('span')
                    //   .append(area),
                    (osmId && osmType) ? createElement('a')
                    .setAttribute('target', '_blank')
                    .setAttribute('href', `https://openstreetmap.org/${osmTypeName[osmType]}/${osmId}`)
                    .append(osmType + '/' + osmId) : ''
                  )
              ),
            ...Object.keys(tags).sort().map(key => {
              let value = tags[key];
              let valueHref = externalLinkForValue(key, value, tags);
              let valElement = valueHref ? createElement('a')
                  .setAttribute('target', '_blank')
                  .setAttribute('rel', 'nofollow')
                  .setAttribute('href', valueHref)
                  .append(value) : value;
                
              let keyHref = key.startsWith('r.') ? `https://wiki.openstreetmap.org/wiki/Key:${key.substring(2)}` : 
                key.startsWith('m.') ? `https://www.openstreetmap.org/relation/${key.substring(2)}` :
                `https://wiki.openstreetmap.org/wiki/Key:${key}`;
          
              return createElement('tr')
                .append(
                  createElement('td')
                    .append(
                      createElement('a')
                        .setAttribute('target', '_blank')
                        .setAttribute('href', keyHref)
                        .append(key)
                    ),
                  createElement('td')
                    .append(valElement)
                );
            })
          ]
        })
      );

    sidebar
      .replaceChildren(table);
  }
}

function didClickMap(e) {
  let entities = map.queryRenderedFeatures(e.point, queryOpts);

  if (entities.length) {
    isPopupLocked = false;
    processMouseForPopup(e);
    isPopupLocked = true;
  } else {
    sidebar.replaceChildren();
    isPopupLocked = false;
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