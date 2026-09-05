import { useCallback, useEffect, useMemo, useState } from 'react';
import _ from 'underscore';
import { fetchAdminChildren } from '../api';
import AreaMap from './AreaMap';
import { Button, Field, Message, Select, Tag } from './ui';

const Tabs = {
  adminUnits: 'adminUnits',
  draw: 'draw'
};

// The GeoNames hierarchy root; its children are the continents.
const EARTH_GEONAME_ID = 6295630;

/**
 * Collects the atlas's geographic area: either administrative units picked
 * from the GeoNames hierarchy (continent -> country -> state -> counties), or
 * a polygon drawn on a map. The two are mutually exclusive — the import
 * backend treats admin units and drawn geometry as alternative scopes, so
 * filling one clears the other.
 */
const AtlasAreaForm = ({ onChange, projectId, value }) => {
  const [tab, setTab] = useState(value?.geometry_json ? Tabs.draw : Tabs.adminUnits);

  const [continents, setContinents] = useState([]);
  const [countries, setCountries] = useState([]);
  const [states, setStates] = useState([]);
  const [counties, setCounties] = useState([]);

  const [continent, setContinent] = useState('');
  const [country, setCountry] = useState('');
  const [state, setState] = useState('');

  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState(false);

  const units = useMemo(() => value?.admin_units || [], [value]);

  const fetchChildren = useCallback((geonameId) => {
    setLoading(true);
    setLoadError(false);

    return fetchAdminChildren(geonameId, projectId)
      .then((data) => data.geonames || [])
      .catch(() => {
        setLoadError(true);
        return [];
      })
      .finally(() => setLoading(false));
  }, [projectId]);

  useEffect(() => {
    if (tab === Tabs.adminUnits && _.isEmpty(continents)) {
      fetchChildren(EARTH_GEONAME_ID).then(setContinents);
    }
  }, [tab, continents, fetchChildren]);

  const asOptions = (records) => _.map(records, (record) => ({
    value: String(record.geonameId),
    text: record.name
  }));

  /**
   * The admin unit document stored on the area (and consumed by the import
   * backend) for a GeoNames record.
   */
  const asUnit = (record) => _.omit({
    geoname_id: record.geonameId,
    name: record.name,
    country: record.countryCode,
    admin_code1: record.adminCode1,
    admin_code2: record.adminCode2
  }, (v) => v == null || v === '');

  // Selecting units clears any drawn geometry.
  const setUnits = (next) => onChange(_.isEmpty(next) ? {} : { admin_units: next });

  const findRecord = (records, id) => _.find(records, (r) => String(r.geonameId) === String(id));

  const onContinentChange = (id) => {
    setContinent(id);
    setCountry('');
    setState('');
    setCountries([]);
    setStates([]);
    setCounties([]);

    if (id) {
      fetchChildren(id).then(setCountries);
    }
  };

  const onCountryChange = (id) => {
    setCountry(id);
    setState('');
    setStates([]);
    setCounties([]);

    if (id) {
      fetchChildren(id).then(setStates);
    }
  };

  const onStateChange = (id) => {
    setState(id);
    setCounties([]);

    if (id) {
      fetchChildren(id).then(setCounties);
    }
  };

  const isSelected = (record) => !!_.findWhere(units, { geoname_id: record.geonameId });

  const onToggleCounty = (record) => {
    if (isSelected(record)) {
      setUnits(_.filter(units, (u) => u.geoname_id !== record.geonameId));
    } else {
      setUnits([...units, asUnit(record)]);
    }
  };

  const onAddState = () => {
    const record = findRecord(states, state);

    if (record && !isSelected(record)) {
      setUnits([...units, asUnit(record)]);
    }
  };

  const onRemoveUnit = (unit) => setUnits(_.filter(units, (u) => u.geoname_id !== unit.geoname_id));

  // Drawing clears any selected admin units.
  const onMapChange = (data) => onChange(_.isEmpty(data?.features) ? {} : { geometry_json: data });

  return (
    <div className='area-form'>
      <div className='tabs' role='tablist'>
        <button
          aria-selected={tab === Tabs.adminUnits}
          className='tab'
          onClick={() => setTab(Tabs.adminUnits)}
          role='tab'
          type='button'
        >
          Administrative units
        </button>
        <button
          aria-selected={tab === Tabs.draw}
          className='tab'
          onClick={() => setTab(Tabs.draw)}
          role='tab'
          type='button'
        >
          Draw on map
        </button>
      </div>
      { tab === Tabs.adminUnits && (
        <>
          { loadError && (
            <Message tone='negative'>
              Unable to load administrative units. Check the GeoNames configuration and try again.
            </Message>
          )}
          <div className='grid-2'>
            <Field label='Continent'>
              <Select
                loading={loading && _.isEmpty(continents)}
                onChange={onContinentChange}
                options={asOptions(continents)}
                placeholder='Select a continent'
                value={continent}
              />
            </Field>
            <Field label='Country'>
              <Select
                disabled={!continent}
                loading={loading && !!continent && _.isEmpty(countries)}
                onChange={onCountryChange}
                options={asOptions(countries)}
                placeholder='Select a country'
                value={country}
              />
            </Field>
            <Field label='State / region'>
              <Select
                disabled={!country}
                loading={loading && !!country && _.isEmpty(states)}
                onChange={onStateChange}
                options={asOptions(states)}
                placeholder='Select a state or region'
                value={state}
              />
            </Field>
            <div className='field'>
              <span className='field-label'>Counties / districts</span>
              { !state && <p className='muted'>Select a state or region first.</p> }
              { state && loading && _.isEmpty(counties) && <p className='muted'>Loading…</p> }
              { !_.isEmpty(counties) && (
                <div className='scroll-list'>
                  { _.map(counties, (record) => (
                    <label className='check' key={record.geonameId}>
                      <input
                        checked={isSelected(record)}
                        onChange={() => onToggleCounty(record)}
                        type='checkbox'
                      />
                      { record.name }
                    </label>
                  ))}
                </div>
              )}
            </div>
          </div>
          { state && (
            <Button onClick={onAddState} subtle>+ Add the entire state / region</Button>
          )}
          <div className='selected-units'>
            <strong>Selected units</strong>
            { _.isEmpty(units) && (
              <p className='muted'>No units selected yet. Pick counties above, or add the entire state / region.</p>
            )}
            { !_.isEmpty(units) && (
              <div className='tags'>
                { _.map(units, (unit) => (
                  <Tag key={unit.geoname_id} onRemove={() => onRemoveUnit(unit)}>{ unit.name }</Tag>
                ))}
              </div>
            )}
          </div>
        </>
      )}
      { tab === Tabs.draw && (
        <>
          <Message>
            Draw the atlas area as a polygon. Authority imports and the site’s map will be scoped to it.
          </Message>
          <AreaMap
            data={value?.geometry_json}
            onChange={onMapChange}
          />
        </>
      )}
    </div>
  );
};

export default AtlasAreaForm;
