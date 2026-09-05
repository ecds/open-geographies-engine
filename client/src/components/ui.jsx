import _ from 'underscore';

/**
 * Small presentational primitives, so the wizard needs no UI library. Class
 * names map to styles.css.
 */

export const Message = ({ children, header, list, tone = 'info' }) => (
  <div className={`message message-${tone}`} role={tone === 'negative' ? 'alert' : 'status'}>
    { header && <strong className='message-header'>{ header }</strong> }
    { children }
    { !_.isEmpty(list) && (
      <ul>
        { _.map(list, (item, index) => <li key={index}>{ item }</li>) }
      </ul>
    )}
  </div>
);

export const Button = ({ children, loading, primary, subtle, ...props }) => (
  <button
    {...props}
    className={['button', primary && 'button-primary', subtle && 'button-subtle', props.className].filter(Boolean).join(' ')}
    disabled={props.disabled || loading}
    type={props.type || 'button'}
  >
    { loading && <span className='spinner' aria-hidden='true' /> }
    { children }
  </button>
);

export const Field = ({ children, hint, label, required }) => (
  <label className='field'>
    <span className='field-label'>
      { label }
      { required && <span className='required' aria-hidden='true'> *</span> }
    </span>
    { children }
    { hint && <span className='field-hint'>{ hint }</span> }
  </label>
);

export const Select = ({ disabled, loading, onChange, options, placeholder, value }) => (
  <select
    className='input'
    disabled={disabled || loading}
    onChange={(e) => onChange(e.target.value)}
    value={value ?? ''}
  >
    <option value=''>{ loading ? 'Loading…' : placeholder }</option>
    { _.map(options, (option) => (
      <option key={option.value} value={option.value}>{ option.text }</option>
    ))}
  </select>
);

/**
 * A multi-value picker: checkboxes for the known options, with an optional
 * free-text entry for values outside the list (GeoNames feature codes,
 * Wikidata item ids).
 */
export const MultiSelect = ({ allowAdditions, disabled, onChange, options, placeholder, value }) => {
  const known = _.pluck(options, 'value');
  const extras = _.difference(value, known);

  const toggle = (item) => {
    onChange(_.contains(value, item) ? _.without(value, item) : [...value, item]);
  };

  const onAdd = (e) => {
    e.preventDefault();
    const input = e.target.elements.addition;
    const item = input.value.trim();

    if (item && !_.contains(value, item)) {
      onChange([...value, item]);
    }

    input.value = '';
  };

  return (
    <div className={['multiselect', disabled && 'is-disabled'].filter(Boolean).join(' ')}>
      { _.map(options, (option) => (
        <label className='check' key={option.value}>
          <input
            checked={_.contains(value, option.value)}
            disabled={disabled}
            onChange={() => toggle(option.value)}
            type='checkbox'
          />
          { option.text }
        </label>
      ))}
      { !_.isEmpty(extras) && (
        <div className='tags'>
          { _.map(extras, (item) => (
            <Tag key={item} onRemove={disabled ? undefined : () => toggle(item)}>{ item }</Tag>
          ))}
        </div>
      )}
      { allowAdditions && !disabled && (
        <form className='addition' onSubmit={onAdd}>
          <input className='input' name='addition' placeholder={placeholder} />
          <Button subtle type='submit'>Add</Button>
        </form>
      )}
    </div>
  );
};

export const Tag = ({ children, onRemove, tone }) => (
  <span className={['tag', tone && `tag-${tone}`].filter(Boolean).join(' ')}>
    { children }
    { onRemove && (
      <button aria-label='Remove' className='tag-remove' onClick={onRemove} type='button'>×</button>
    )}
  </span>
);

export const Stat = ({ label, tone, value }) => (
  <span className={['stat', tone && `stat-${tone}`].filter(Boolean).join(' ')}>
    <span className='stat-label'>{ label }</span>
    <span className='stat-value'>{ value }</span>
  </span>
);

export const Toggle = ({ checked, disabled, label, onChange }) => (
  <label className='toggle'>
    <input checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} type='checkbox' />
    <span className='toggle-track' aria-hidden='true' />
    { label }
  </label>
);

export const Progress = ({ total, value }) => {
  const percent = total ? Math.min(100, Math.round((value / total) * 100)) : 0;

  return (
    <div className='progress' role='progressbar' aria-valuemin={0} aria-valuemax={total || 0} aria-valuenow={value || 0}>
      <div className='progress-bar' style={{ width: `${percent}%` }} />
      <span className='progress-label'>{ value } / { total }</span>
    </div>
  );
};
