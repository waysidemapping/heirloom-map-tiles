import Pbf from 'https://unpkg.com/pbf@4.0.1/index.js';
import {VectorTile} from 'https://esm.run/@mapbox/vector-tile@2.0.3/index.js';
import tileToProtobuf from 'https://esm.run/vt-pbf@3.1.3/index.js';

export async function beefsteakProtocolFunction(request) {
  const url = request.url.replace('beefsteak://', '');
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
          .reduce((acc, [layerId, layer]) => ({
          ...acc,
          [layerId]: {
            ...layer,
            feature: (index) => {
              const feature = layer.feature(index);

              if (feature.id % 10 === 3) { // relation
                if (Object.keys(feature.properties).length === 0) {
                  // for relations with no properties, attempt to populate with data from the relation layer

                  const id = Math.floor(feature.id * 0.1);
                  const relation = relationsById[id];

                  if (relation) {
                    for (const prop in relation.properties) {
                      feature.properties[prop] = relation.properties[prop];
                    }
                  }
                }

              } else { // non-relation
                // add relation tags based on relation properties given in the format `m.{relation_id}={member_role}`

                const linkedRelations = Object.keys(feature.properties)
                  .filter(key => key.startsWith('m.'))
                  .map(key => parseInt(key.substring(2)))
                  .sort((a, b) => a - b)
                  .map(id => relationsById[id])
                  .filter(Boolean);

                if (linkedRelations.length) {
                  for (const key of allRelationKeys) {
                    const values = linkedRelations.map(rel => rel.properties[key]);
                    const joined = '┃' + values.join('┃') + '┃';

                    // only add the property if at least one of the relations has a value
                    if (joined.length > linkedRelations.length + 1) {
                      feature.properties['r.' + key] = joined;
                    }
                  }
                }
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