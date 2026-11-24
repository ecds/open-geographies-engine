import _ from 'underscore';
import { Button, Select } from './ui';

/**
 * The icons in the renderer's map sprite (core-data-places: icons/, built by
 * `npm run build:sprites`). Keep in step with icons/MANIFEST.json there: a
 * name the sprite doesn't have draws no icon on the map.
 */
export const MAP_ICONS = [
  'beach', 'bridge', 'building', 'cemetery', 'church', 'coral-reef', 'forest', 'fort', 'golf',
  'government', 'harbor-11', 'hospital', 'house', 'island', 'library', 'lighthouse', 'marker',
  'mountain', 'museum', 'park', 'plane', 'school', 'sinking-ship', 'tower', 'train', 'tree',
  'water', 'water-flow'
];

const DEFAULT_COLOR = '#BC2635';

/**
 * An icon and colour for each place type on a vector tile overlay (the
 * renderer's `type_icons`: { "Church": { "icon": "church", "color": "#1e40af" } }).
 * Order matters: a place with several types takes the first listed one that
 * has an icon, so rows keep their order. Places of other types stay dots.
 *
 * @param types     the atlas's type names, to choose from
 * @param value     the layer's type_icons
 * @param onChange  called with the new type_icons, or undefined when empty
 */
const TypeIconsEditor = ({ onChange, types, value }) => {
  const rows = _.map(value || {}, (entry, type) => ({ type, icon: entry?.icon || '', color: entry?.color || DEFAULT_COLOR }));

  const emit = (next) => {
    const kept = _.filter(next, (row) => row.type);
    onChange(kept.length ? _.object(_.map(kept, (row) => [row.type, { icon: row.icon || 'marker', color: row.color }])) : undefined);
  };

  const update = (index, changes) => emit(_.map(rows, (row, i) => (i === index ? { ...row, ...changes } : row)));

  // Each type once: a row offers the types no other row has taken.
  const typeOptions = (current) => _.map(
    _.filter(types || [], (type) => type === current || !_.some(rows, (row) => row.type === type)),
    (type) => ({ value: type, text: type })
  );

  const iconOptions = _.map(MAP_ICONS, (icon) => ({ value: icon, text: icon }));
  const unused = _.find(types || [], (type) => !_.some(rows, (row) => row.type === type));

  return (
    <div className='type-icons'>
      <span className='field-label'>Icons by type</span>
      <p className='field-hint'>
        Draw places of a type with an icon and colour instead of a dot. A place with several types takes the first one listed here.
      </p>
      { _.map(rows, (row, index) => (
        <div className='type-icons-row' key={row.type || index}>
          <Select
            ariaLabel='Type'
            onChange={(type) => update(index, { type })}
            options={typeOptions(row.type)}
            placeholder='Choose a type'
            value={row.type}
          />
          <Select
            ariaLabel={`Icon for ${row.type}`}
            onChange={(icon) => update(index, { icon })}
            options={iconOptions}
            placeholder='Choose an icon'
            value={row.icon}
          />
          <input
            aria-label={`Colour for ${row.type}`}
            className='type-icons-color'
            onChange={(e) => update(index, { color: e.target.value })}
            type='color'
            value={row.color}
          />
          <Button onClick={() => emit(_.reject(rows, (r, i) => i === index))} subtle>Remove</Button>
        </div>
      ))}
      { unused && (
        <Button onClick={() => emit([...rows, { type: unused, icon: 'marker', color: DEFAULT_COLOR }])} subtle>+ Add an icon</Button>
      )}
      { _.isEmpty(types) && <p className='muted'>This atlas has no types yet.</p> }
    </div>
  );
};

export default TypeIconsEditor;
