import { GeoJsonLayer } from '@performant-software/geospatial';
import { useCallback, useEffect, useMemo, useState } from 'react';
import _ from 'underscore';
import { createPlaceImport, errorMessages, previewPlaceImport } from '../api';
import { isTerminal, JobStatuses } from '../jobs';
import useJobPolling from '../hooks/useJobPolling';
import AreaMap from './AreaMap';
import AtlasAreaForm from './AtlasAreaForm';
import JobStatus from './JobStatus';
import {
  Button,
  Field,
  Message,
  MultiSelect,
  Progress,
  Stat,
  Toggle
} from './ui';

const Sources = {
  geonames: 'geonames',
  wikidata: 'wikidata'
};

const SOURCE_LABELS = {
  geonames: 'GeoNames',
  wikidata: 'Wikidata'
};

const FEATURE_CLASSES = [
  { value: 'A', text: 'A — Countries, states, regions' },
  { value: 'H', text: 'H — Streams, lakes, bays' },
  { value: 'L', text: 'L — Parks, areas' },
  { value: 'P', text: 'P — Cities, towns, villages' },
  { value: 'R', text: 'R — Roads, railroads, trails' },
  { value: 'S', text: 'S — Spots, buildings, farms' },
  { value: 'T', text: 'T — Mountains, hills, rocks' },
  { value: 'U', text: 'U — Undersea features' },
  { value: 'V', text: 'V — Forests, heath' }
];

const WIKIDATA_TYPES = [
  { value: 'Q486972', text: 'Settlements (Q486972)' },
  { value: 'Q41176', text: 'Buildings (Q41176)' },
  { value: 'Q570116', text: 'Tourist attractions (Q570116)' },
  { value: 'Q33506', text: 'Museums (Q33506)' },
  { value: 'Q839954', text: 'Archaeological sites (Q839954)' },
  { value: 'Q24398318', text: 'Religious buildings (Q24398318)' },
  { value: 'Q3914', text: 'Schools (Q3914)' },
  { value: 'Q22698', text: 'Parks (Q22698)' },
  { value: 'Q4989906', text: 'Monuments (Q4989906)' },
  { value: 'Q1248784', text: 'Airports (Q1248784)' }
];

const PREVIEW_LIMIT = 500;

// GeoJsonLayer reads `lineStyle` but defaults `strokeStyle`, so without an
// explicit value its line layer has no paint and MapLibre rejects it.
const LINE_STYLE = { 'line-width': 0 };

const POINT_STYLES = {
  geonames: { 'circle-radius': 4, 'circle-color': '#f2711c', 'circle-opacity': 0.8 },
  wikidata: { 'circle-radius': 4, 'circle-color': '#2185d0', 'circle-opacity': 0.8 }
};

/**
 * The authority bulk-import panel: pick sources and filters for the area,
 * preview the match count and sample points on a map, then run the imports
 * as background jobs (one per source, sequentially) with inline progress.
 * Imports are idempotent, so the panel is safe to re-run with an expanded
 * area or new sources.
 */
const PlaceImportPanel = ({ area: initialArea, onImported, projectId }) => {
  const [area, setArea] = useState(initialArea || {});

  const [geonames, setGeonames] = useState({
    enabled: true,
    feature_classes: ['P'],
    feature_codes: [],
    name: ''
  });

  const [wikidata, setWikidata] = useState({
    enabled: false,
    types: ['Q486972']
  });

  const [preview, setPreview] = useState(null);
  const [previewLoading, setPreviewLoading] = useState(false);

  const [queue, setQueue] = useState([]);
  const [currentSource, setCurrentSource] = useState(null);
  const [currentJobId, setCurrentJobId] = useState(null);
  const [results, setResults] = useState([]);

  const [errors, setErrors] = useState([]);

  const job = useJobPolling(currentJobId);

  const hasArea = useMemo(() => (
    !_.isEmpty(area?.admin_units) || !_.isEmpty(area?.geometry_json)
  ), [area]);

  // Wikidata queries by bounding box, so it needs a drawn geometry.
  const wikidataAvailable = useMemo(() => !_.isEmpty(area?.geometry_json), [area]);

  useEffect(() => {
    if (!wikidataAvailable && wikidata.enabled) {
      setWikidata((prev) => ({ ...prev, enabled: false }));
    }
  }, [wikidataAvailable, wikidata.enabled]);

  const enabledSources = useMemo(() => _.compact([
    geonames.enabled && Sources.geonames,
    wikidata.enabled && Sources.wikidata
  ]), [geonames.enabled, wikidata.enabled]);

  const importing = !!currentJobId;

  const buildPlaceImport = useCallback((source) => {
    let filters;

    if (source === Sources.geonames) {
      filters = _.omit({
        feature_classes: geonames.feature_classes,
        feature_codes: geonames.feature_codes,
        name: geonames.name
      }, (v) => _.isEmpty(v));
    } else {
      filters = { types: wikidata.types };
    }

    return { source, area, filters };
  }, [area, geonames, wikidata]);

  /**
   * Each source previews independently: one source failing (bad
   * credentials, unsupported area) should not discard the others.
   */
  const onPreview = useCallback(() => {
    setPreviewLoading(true);
    setPreview(null);
    setErrors([]);

    Promise
      .all(_.map(enabledSources, (source) => (
        previewPlaceImport(projectId, buildPlaceImport(source), PREVIEW_LIMIT)
          .then((data) => ({ source, data }))
          .catch((error) => ({ source, error: errorMessages(error).join(', ') }))
      )))
      .then((entries) => {
        const succeeded = _.filter(entries, (entry) => entry.data);
        const failed = _.filter(entries, (entry) => entry.error);

        setPreview(_.isEmpty(succeeded) ? null : _.object(_.map(succeeded, ({ source, data }) => [source, data])));
        setErrors(_.map(failed, ({ source, error }) => `Preview failed (${SOURCE_LABELS[source]}): ${error}`));
      })
      .finally(() => setPreviewLoading(false));
  }, [buildPlaceImport, enabledSources, projectId]);

  const startImport = useCallback((source) => {
    setCurrentSource(source);

    createPlaceImport(projectId, buildPlaceImport(source))
      .then((data) => setCurrentJobId(data.job.id))
      .catch((error) => {
        setErrors([`Import failed: ${errorMessages(error).join(', ')}`]);
        setCurrentSource(null);
        setQueue([]);
      });
  }, [buildPlaceImport, projectId]);

  const onImport = useCallback(() => {
    setErrors([]);

    const [first, ...rest] = enabledSources;

    setQueue(rest);
    startImport(first);
  }, [enabledSources, startImport]);

  /**
   * When the current job finishes, records the result and starts the next
   * queued source (if any).
   */
  useEffect(() => {
    if (!job || !isTerminal(job.status) || _.findWhere(results, { jobId: job.id })) {
      return;
    }

    setResults((prev) => [...prev, { source: currentSource, jobId: job.id, job }]);
    setCurrentJobId(null);

    if (job.status === JobStatuses.completed && onImported) {
      onImported();
    }

    const [next, ...rest] = queue;

    if (next) {
      setQueue(rest);
      startImport(next);
    } else {
      setCurrentSource(null);
    }
  }, [job, currentSource, queue, results, startImport, onImported]);

  const asFeatureCollection = (sample) => ({
    type: 'FeatureCollection',
    features: _.map(sample, (record) => ({
      type: 'Feature',
      properties: { name: record.name },
      geometry: { type: 'Point', coordinates: [record.longitude, record.latitude] }
    }))
  });

  /**
   * The geometry used to frame the preview map: the drawn area when one
   * exists, otherwise the bounding box of the sample points.
   */
  const previewFrame = useMemo(() => {
    if (!preview) {
      return null;
    }

    if (!_.isEmpty(area?.geometry_json)) {
      return area.geometry_json;
    }

    const coordinates = _.flatten(_.map(_.values(preview), ({ sample }) => (
      _.map(sample, (record) => [record.longitude, record.latitude])
    )), true);

    if (_.isEmpty(coordinates)) {
      return null;
    }

    const longitudes = _.map(coordinates, (c) => c[0]);
    const latitudes = _.map(coordinates, (c) => c[1]);
    const west = _.min(longitudes);
    const south = _.min(latitudes);
    const east = _.max(longitudes);
    const north = _.max(latitudes);

    return {
      type: 'FeatureCollection',
      features: [{
        type: 'Feature',
        properties: {},
        geometry: {
          type: 'Polygon',
          coordinates: [[[west, south], [east, south], [east, north], [west, north], [west, south]]]
        }
      }]
    };
  }, [area, preview]);

  const previewTotal = preview && _.reduce(_.values(preview), (sum, { count }) => sum + (count || 0), 0);
  const previewSampleCount = preview && _.reduce(_.values(preview), (sum, { sample }) => sum + (sample?.length || 0), 0);
  const previewWarnings = preview && _.compact(_.flatten(_.map(_.values(preview), ({ warnings }) => warnings)));

  const renderResult = ({ source, job: resultJob }) => {
    const { counts, duplicates, warnings, error } = resultJob.extra || {};

    return (
      <div className='card' key={resultJob.id}>
        <h4>{ SOURCE_LABELS[source] } <JobStatus status={resultJob.status} /></h4>
        { counts && (
          <div className='stats'>
            <Stat label='Imported' tone='positive' value={counts.imported} />
            <Stat label='Already imported' value={counts.skipped} />
            <Stat label='Outside area' value={counts.outside_area} />
            { counts.failed > 0 && <Stat label='Failed' tone='negative' value={counts.failed} /> }
          </div>
        )}
        { error && <Message tone='negative'>{ error }</Message> }
        { !_.isEmpty(warnings) && <Message header='Warnings' list={warnings} tone='warning' /> }
        { !_.isEmpty(duplicates) && (
          <>
            <h5>Possible cross-source duplicates</h5>
            <ul>
              { _.map(_.first(duplicates, 25), (duplicate, index) => (
                <li key={index}>{ duplicate.name } (#{ duplicate.imported_id } / #{ duplicate.existing_id })</li>
              ))}
            </ul>
          </>
        )}
      </div>
    );
  };

  const canRun = hasArea && !_.isEmpty(enabledSources) && !previewLoading && !importing;

  return (
    <div className='import-panel'>
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }

      <h3>Import area</h3>
      <AtlasAreaForm onChange={setArea} projectId={projectId} value={area} />

      <h3>Sources</h3>
      <div className='card'>
        <Toggle
          checked={geonames.enabled}
          label='GeoNames'
          onChange={(enabled) => setGeonames((prev) => ({ ...prev, enabled }))}
        />
        { geonames.enabled && (
          <div className='grid-3'>
            <Field label='Feature classes' hint='Leave all unchecked for every class.'>
              <MultiSelect
                onChange={(feature_classes) => setGeonames((prev) => ({ ...prev, feature_classes }))}
                options={FEATURE_CLASSES}
                value={geonames.feature_classes}
              />
            </Field>
            <Field label='Feature codes (optional)'>
              <MultiSelect
                allowAdditions
                onChange={(feature_codes) => setGeonames((prev) => ({ ...prev, feature_codes }))}
                options={[]}
                placeholder='e.g. PPL, CH, SCH'
                value={geonames.feature_codes}
              />
            </Field>
            <Field label='Name contains (optional)'>
              <input
                className='input'
                onChange={(e) => setGeonames((prev) => ({ ...prev, name: e.target.value }))}
                placeholder='Filter by name'
                value={geonames.name}
              />
            </Field>
          </div>
        )}
      </div>
      <div className='card'>
        <Toggle
          checked={wikidata.enabled}
          disabled={!wikidataAvailable}
          label='Wikidata'
          onChange={(enabled) => setWikidata((prev) => ({ ...prev, enabled }))}
        />
        { !wikidataAvailable && (
          <p className='muted'>Wikidata searches by bounding box — draw the area on the map to enable it.</p>
        )}
        { wikidata.enabled && (
          <Field label='Place types'>
            <MultiSelect
              allowAdditions
              onChange={(types) => setWikidata((prev) => ({ ...prev, types }))}
              options={WIKIDATA_TYPES}
              placeholder='Add a Wikidata item id, e.g. Q839954'
              value={wikidata.types}
            />
          </Field>
        )}
      </div>

      { !hasArea && <Message tone='warning'>Pick administrative units or draw an area first.</Message> }
      { _.isEmpty(enabledSources) && <Message tone='warning'>Enable at least one source to import from.</Message> }

      <div className='actions'>
        <Button disabled={!canRun} loading={previewLoading} onClick={onPreview}>Preview</Button>
        <Button disabled={!canRun} loading={importing} onClick={onImport} primary>Import</Button>
      </div>
      <p className='muted'>
        Preview fetches the match count and a sample of up to { PREVIEW_LIMIT } points — nothing is imported yet.
      </p>

      { preview && (
        <div className='card'>
          <h4>Preview</h4>
          <div className='stats'>
            <Stat label='Places match' value={previewTotal} />
            { _.map(_.keys(preview), (source) => (
              <Stat key={source} label={SOURCE_LABELS[source]} tone={source} value={preview[source].count} />
            ))}
          </div>
          { !_.isEmpty(previewWarnings) && <Message list={previewWarnings} tone='warning' /> }
          <p className='muted'>Showing { previewSampleCount } sample points</p>
          <AreaMap data={previewFrame}>
            { _.map(_.keys(preview), (source) => (
              <GeoJsonLayer
                data={asFeatureCollection(preview[source].sample)}
                key={source}
                lineStyle={LINE_STYLE}
                pointStyle={POINT_STYLES[source]}
              />
            ))}
          </AreaMap>
        </div>
      )}

      { importing && (
        <div className='card'>
          <Message>Importing from { SOURCE_LABELS[currentSource] }…</Message>
          { job?.extra?.progress && (
            <Progress total={job.extra.progress.total} value={job.extra.progress.completed} />
          )}
        </div>
      )}

      { !_.isEmpty(results) && (
        <>
          <h3>Import results</h3>
          { _.map(results, renderResult) }
          { !importing && (
            <Message tone='positive'>
              Imports complete. New places are searchable as soon as the reindex finishes.
            </Message>
          )}
        </>
      )}
    </div>
  );
};

export default PlaceImportPanel;
