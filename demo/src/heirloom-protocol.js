import Pbf from 'https://unpkg.com/pbf@4.0.1/index.js';
import {VectorTile} from 'https://esm.run/@mapbox/vector-tile@2.0.3/index.js';
import tileToProtobuf from 'https://esm.run/vt-pbf@3.1.3/index.js';

export async function heirloomProtocolFunction(request) {
  const url = request.url.replace('heirloom://', '');
  return fetch(url)
    .then((response) => response.arrayBuffer())
    .then((buffer) => new VectorTile(new Pbf(buffer)))
    .then((tile) => {
      const relationLayer = tile.layers.relation;
      const relationCount = relationLayer?.length;
      if (!(relationCount > 0)) return tile;
      const allRelationKeys = relationLayer._keys;
      let relationsById = {};
      for (let i = 0; i < relationCount; i += 1) {
        let relation = relationLayer.feature(i);
        relationsById[Math.floor(relation.id * 0.1)] = relation;
      }
      return {
        layers: Object.entries(tile.layers)
          // don't include relations layer in the output since we're folding it into the other layers
          .filter(([layerId, _]) => layerId != 'relation')
          .reduce((acc, [layerId, layer]) => ({
          ...acc,
          [layerId]: {
            ...layer,
            feature: (index) => {
              const feature = layer.feature(index);
              const linkedRelations = Object.keys(feature.properties)
                .filter(key => key.startsWith('m.'))
                .map(key => parseInt(key.substring(2)))
                .sort((a, b) => a - b)
                .map(id => relationsById[id])
                .filter(Boolean);

              if (linkedRelations.length) {
                feature.properties = {
                  ...feature.properties,
                  ...Object.fromEntries(
                    Object.entries(
                      allRelationKeys.reduce((acc, key) => {
                        return {...acc, ['r.' + key]: '┃' + linkedRelations.map(rel => rel.properties[key]).join('┃') + '┃'};
                      }, {})
                    )
                    // remove relation properties that don't have any values
                    .filter(([_, v]) => v.length > linkedRelations.length + 1)
                  )
                };
              }

              return feature;
            }
          }
        }), {})
      };
    })
    .then((tile) => tileToProtobuf(tile).buffer)
    .then((data) => ({ data }));
}