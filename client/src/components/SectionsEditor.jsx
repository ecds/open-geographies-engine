import _ from 'underscore';
import ImageField from './ImageField';
import { CROP_SHAPES } from './ImageCropper';
import MarkdownField from './MarkdownField';
import { Button, Field, Select, Toggle } from './ui';

export const SECTION_TYPES = [
  { value: 'hero', text: 'Banner', description: 'A large title over the brand color or an image, with an optional search box and button.' },
  { value: 'text', text: 'Text', description: 'A heading and formatted text.' },
  { value: 'text_image', text: 'Text and image', description: 'Text beside an image.' },
  { value: 'call_to_action', text: 'Call to action', description: 'A short prompt with a button, e.g. into the map.' }
];

const LABELS = _.object(_.pluck(SECTION_TYPES, 'value'), _.pluck(SECTION_TYPES, 'text'));

export const newSectionId = () => Math.random().toString(36).slice(2, 10);

const LINK_HINT = 'A page on this atlas (/en/search/places) or a full address (https://…).';

/**
 * The ordered sections of a page (the home page or a standalone page), each
 * with the fields its type has, and buttons to add, move and remove them.
 */
const SectionsEditor = ({ assets, fallbackTitle, onChange, onUpload, sections = [] }) => {
  const update = (index, changes) => onChange(sections.map((s, i) => (i === index ? { ...s, ...changes } : s)));
  const remove = (index) => onChange(_.reject(sections, (s, i) => i === index));

  const move = (index, offset) => {
    const target = index + offset;

    if (target < 0 || target >= sections.length) {
      return;
    }

    const next = [...sections];
    [next[index], next[target]] = [next[target], next[index]];
    onChange(next);
  };

  const add = (type) => onChange([...sections, { id: newSectionId(), type, ...(type === 'text_image' ? { image_position: 'right' } : {}) }]);

  const button = (section, index) => (
    <div className='grid-2'>
      <Field label='Button text'>
        <input className='input' onChange={(e) => update(index, { button_text: e.target.value })} placeholder='e.g. Explore the map' value={section.button_text || ''} />
      </Field>
      <Field hint={LINK_HINT} label='Button link'>
        <input className='input' onChange={(e) => update(index, { button_url: e.target.value })} placeholder='/en/search/places' value={section.button_url || ''} />
      </Field>
    </div>
  );

  const markdown = (section, index, label = 'Text', rows = 8) => (
    <MarkdownField
      assets={assets}
      label={label}
      onChange={(body) => update(index, { body })}
      onUpload={onUpload}
      rows={rows}
      value={section.body}
    />
  );

  const image = (section, index, label) => (
    <ImageField
      alt={section.image_alt}
      assets={assets}
      crop={section.type === 'hero' ? CROP_SHAPES.banner : undefined}
      label={label}
      onAltChange={(image_alt) => update(index, { image_alt })}
      onChange={(path) => update(index, { image: path })}
      onUpload={onUpload}
      value={section.image}
    />
  );

  const fields = (section, index) => {
    switch (section.type) {
      case 'hero':
        return (
          <>
            <Field hint={fallbackTitle ? `Leave blank to show "${fallbackTitle}".` : undefined} label='Title'>
              <input className='input' onChange={(e) => update(index, { title: e.target.value })} placeholder={fallbackTitle} value={section.title || ''} />
            </Field>
            <Field label='Subtitle'>
              <input className='input' onChange={(e) => update(index, { subtitle: e.target.value })} value={section.subtitle || ''} />
            </Field>
            { image(section, index, 'Background image') }
            <div className='row section-search'>
              <Toggle checked={section.search === true} label='Search box' onChange={(search) => update(index, { search })} />
              { section.search && (
                <input
                  aria-label='Search box placeholder'
                  className='input'
                  onChange={(e) => update(index, { search_placeholder: e.target.value })}
                  placeholder='Placeholder, e.g. Search places'
                  value={section.search_placeholder || ''}
                />
              )}
            </div>
            { button(section, index) }
          </>
        );
      case 'text':
        return (
          <>
            <Field label='Heading'>
              <input className='input' onChange={(e) => update(index, { title: e.target.value })} value={section.title || ''} />
            </Field>
            { markdown(section, index) }
          </>
        );
      case 'text_image':
        return (
          <>
            <Field label='Heading'>
              <input className='input' onChange={(e) => update(index, { title: e.target.value })} value={section.title || ''} />
            </Field>
            { markdown(section, index, 'Text', 6) }
            { image(section, index, 'Image') }
            <Field label='Image side'>
              <Select
                onChange={(v) => update(index, { image_position: v || 'right' })}
                options={[{ value: 'left', text: 'Left of the text' }, { value: 'right', text: 'Right of the text' }]}
                placeholder='Right of the text'
                value={section.image_position || 'right'}
              />
            </Field>
            { button(section, index) }
          </>
        );
      case 'call_to_action':
        return (
          <>
            <Field label='Heading'>
              <input className='input' onChange={(e) => update(index, { title: e.target.value })} value={section.title || ''} />
            </Field>
            { markdown(section, index, 'Text', 3) }
            { button(section, index) }
          </>
        );
      default:
        return <p className='muted'>This section type isn't editable here.</p>;
    }
  };

  return (
    <div className='sections'>
      { _.isEmpty(sections) && <p className='muted'>No sections yet. Add one below.</p> }
      { _.map(sections, (section, index) => (
        <div className='card section-card' key={section.id || index}>
          <div className='section-head'>
            <h4>{ LABELS[section.type] || section.type }</h4>
            <div className='section-controls'>
              <Button aria-label='Move up' disabled={index === 0} onClick={() => move(index, -1)} subtle>↑</Button>
              <Button aria-label='Move down' disabled={index === sections.length - 1} onClick={() => move(index, 1)} subtle>↓</Button>
              <Button onClick={() => remove(index)} subtle>Remove</Button>
            </div>
          </div>
          { fields(section, index) }
        </div>
      ))}
      <div className='add-section'>
        <span className='muted'>Add a section:</span>
        { _.map(SECTION_TYPES, (type) => (
          <Button key={type.value} onClick={() => add(type.value)} subtle title={type.description}>+ { type.text }</Button>
        ))}
      </div>
    </div>
  );
};

export default SectionsEditor;
