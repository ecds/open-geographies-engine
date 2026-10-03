import { useState } from 'react';
import _ from 'underscore';
import { errorMessages, geocodeDatasetImport } from '../api';
import { Button, Message, Select, Stat } from './ui';

// The parts of an address; each comes from a column, or (city, state, ZIP)
// from a value typed once for every row.
const PARTS = [
  { key: 'street', label: 'Street address', typed: false },
  { key: 'city', label: 'City', typed: true },
  { key: 'state', label: 'State', typed: true, placeholder: 'e.g. GA' },
  { key: 'zip', label: 'ZIP code', typed: true }
];

const REASONS = {
  not_found: 'not found',
  tie: 'matches more than one place',
  other_town: 'found only in another town',
  no_address: 'no street address'
};

/**
 * Rows of an upload that have no coordinates, looked up from their address
 * before importing: the curator says which columns make the address (or
 * types the city or state every row shares), presses Find locations, and
 * sees what was found on the preview map and which rows weren't. The import
 * then looks up every row the same way. `config` is the address definition
 * sent with the import; `result` the last lookup.
 */
const AddressLookup = ({ blobId, columns, config, missing, onConfigChange, onResult, onUseChange, projectId, provider, result, use }) => {
  const [loading, setLoading] = useState(false);
  const [errors, setErrors] = useState([]);

  const columnOptions = _.map(columns, (column) => ({ value: column.name, text: column.name }));

  const setPart = (changes) => {
    onConfigChange({ ...config, ...changes });
    onResult(null);
  };

  const onFind = () => {
    setLoading(true);
    setErrors([]);

    geocodeDatasetImport(projectId, {
      blob_id: blobId,
      columns: _.map(columns, (c) => _.pick(c, 'name', 'role')),
      geocode: _.pick(config, (value) => !_.isEmpty(value))
    })
      .then((data) => {
        onResult(data.geocode);
        onUseChange(true);
      })
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => setLoading(false));
  };

  const counts = result?.counts || {};
  const exactOnly = !!config.exact_only;
  const found = (counts.exact || 0) + (exactOnly ? 0 : (counts.approximate || 0));
  const missed = _.reduce(_.pick(counts, _.keys(REASONS)), (sum, n) => sum + n, 0) + (exactOnly ? (counts.approximate || 0) : 0);

  return (
    <div className='address-lookup'>
      <h3 className='h-sub'>Find locations from addresses</h3>
      <p className='muted'>
        { missing } { missing === 1 ? 'row has' : 'rows have' } no coordinates. Rows with a street address can be
        placed by looking the address up with { provider } (U.S. addresses only). Anything not found is imported
        without a location: listed and searchable, but not on the map.
      </p>
      <div className='address-parts'>
        { _.map(PARTS, (part) => (
          <div className='field' key={part.key}>
            <span className='field-label'>{ part.label }</span>
            <Select
              onChange={(value) => setPart({ [part.key]: value || undefined, ...(value ? { [`${part.key}_value`]: undefined } : {}) })}
              options={columnOptions}
              placeholder={part.typed ? 'No column' : 'Choose a column…'}
              value={config[part.key]}
            />
            { part.typed && !config[part.key] && (
              <input
                aria-label={`${part.label} for every row`}
                className='input'
                onChange={(e) => setPart({ [`${part.key}_value`]: e.target.value })}
                placeholder={part.placeholder || 'or the same for every row'}
                value={config[`${part.key}_value`] || ''}
              />
            )}
          </div>
        ))}
      </div>
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      <div className='row'>
        <Button disabled={!config.street} loading={loading} onClick={onFind}>Find locations</Button>
        { !config.street && <span className='muted'>Choose the column that holds the street address.</span> }
      </div>

      { result && (
        <>
          <div className='stats'>
            <Stat label='Found' tone='positive' value={found} />
            { counts.approximate > 0 && !exactOnly && <Stat label='Of those, near the address' value={counts.approximate} /> }
            { missed > 0 && <Stat label='Not placed' value={missed} /> }
          </div>
          { counts.approximate > 0 && (
            <>
              <label className='column-option'>
                <input
                  checked={!exactOnly}
                  onChange={(e) => onConfigChange({ ...config, exact_only: e.target.checked ? undefined : true })}
                  type='checkbox'
                />
                Include the { counts.approximate } { counts.approximate === 1 ? 'match' : 'matches' } near the address, not
                exactly at it (check them below: an old street name can match a similar street)
              </label>
              { !_.isEmpty(result.approximate) && (
                <Message
                  header='Near the address'
                  list={_.map(result.approximate, (row) => `${row.name || 'Unnamed'}: ${row.address} → ${row.matched}`)}
                  tone='info'
                />
              )}
            </>
          )}
          { result.looked_up < result.without_location && (
            <p className='muted'>
              Looked up the first { result.looked_up } of { result.without_location }; the import looks up all of them.
            </p>
          )}
          { !_.isEmpty(result.not_found) && (
            <Message
              header='Not placed (they import without a location)'
              list={_.map(result.not_found, (row) => `${row.name || 'Unnamed'}: ${row.address || 'no address'} (${REASONS[row.status] || row.status})`)}
              tone='warning'
            />
          )}
          { found > 0 && (
            <label className='column-option'>
              <input checked={use} onChange={(e) => onUseChange(e.target.checked)} type='checkbox' />
              Use the { found } found { found === 1 ? 'location' : 'locations' } when importing (shown in orange on the map above)
            </label>
          )}
        </>
      )}
    </div>
  );
};

export default AddressLookup;
