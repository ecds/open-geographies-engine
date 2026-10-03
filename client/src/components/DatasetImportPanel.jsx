import {
  Fragment,
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useMemo,
  useState
} from 'react';
import _ from 'underscore';
import { createDatasetImport, errorMessages, previewDatasetImport } from '../api';
import useJobPolling from '../hooks/useJobPolling';
import { isTerminal, JobStatuses } from '../jobs';
import AddressLookup from './AddressLookup';
import JobStatus from './JobStatus';
import CopyPhotosStatus from './CopyPhotosStatus';
import FeedbackLink from './FeedbackLink';
import ReindexStatus from './ReindexStatus';
import {
  Button,
  Message,
  Progress,
  Select,
  Stat
} from './ui';

// Loaded on first preview: it carries its own copy of MapLibre (the map
// package bundles another), which the rest of the console never needs.
const PreviewMap = lazy(() => import('./PreviewMap'));

const ACCEPT = '.csv,.tsv,.txt,.xlsx,.ods,.geojson,.json,.kml,.kmz,.zip';

const ROLES = [
  { value: 'name', text: 'Place name' },
  { value: 'field', text: 'Field' },
  { value: 'types', text: 'Category' },
  { value: 'latitude', text: 'Latitude' },
  { value: 'longitude', text: 'Longitude' },
  { value: 'geometry', text: 'Geometry' },
  { value: 'identifier', text: 'Identifier' },
  { value: 'photo', text: 'Photo (image address)' },
  { value: 'skip', text: 'Don\u2019t import' }
];

// Roles a file can have at most one of; choosing one moves it off the
// column that had it.
const SINGLE_ROLES = ['name', 'latitude', 'longitude', 'geometry', 'identifier', 'photo'];

const TYPES = [
  { value: 'String', text: 'Short text' },
  { value: 'Text', text: 'Long text' },
  { value: 'Select', text: 'Pick-list (filterable)' },
  { value: 'Number', text: 'Number' },
  { value: 'Boolean', text: 'Yes / No' },
  { value: 'FuzzyDate', text: 'Date (a year, month or day)' },
  { value: 'Date', text: 'Exact date (YYYY-MM-DD)' }
];

// How the misfit warning names each type's values.
const TYPE_VALUES = {
  Number: 'numbers',
  Boolean: 'yes/no values',
  FuzzyDate: 'dates',
  Date: 'exact dates (YYYY-MM-DD)'
};

const GEOMETRY_LABELS = {
  Point: 'Points',
  MultiPoint: 'Multi-points',
  LineString: 'Lines',
  MultiLineString: 'Multi-lines',
  Polygon: 'Areas',
  MultiPolygon: 'Multi-areas',
  GeometryCollection: 'Collections'
};

/**
 * The preview's columns with the curator's choices from the last upload into
 * this model applied where the column names match (`column.previous`). A
 * one-per-file role taken from the last upload moves off any other column
 * the suggestions had given it.
 */
const withPreviousChoices = (columns) => {
  const taken = _.chain(columns).pluck('previous').compact().pluck('role').intersection(SINGLE_ROLES).value();

  return _.map(columns, (column) => {
    if (column.previous) {
      return { ..._.omit(column, 'existing', 'field_uuid'), ...column.previous };
    }

    if (_.contains(taken, column.role)) {
      return { ...column, role: column.role === 'name' ? 'field' : 'skip' };
    }

    return { ...column };
  });
};

// Field names match the way the server matches them (Rails' parameterize).
const fieldKey = (label) => (label || '')
  .toLowerCase()
  .normalize('NFKD')
  .replace(/[\u0300-\u036f]/g, '')
  .replace(/[^a-z0-9]+/g, '-')
  .replace(/^-+|-+$/g, '');

/**
 * Mirrors the server's checks so the curator sees what to fix before
 * pressing Import.
 */
const validate = (columns) => {
  const count = (role) => _.filter(columns, (c) => c.role === role).length;
  const problems = [];

  if (count('name') !== 1) {
    problems.push('Choose one column as the place name.');
  }

  if (count('latitude') !== count('longitude')) {
    problems.push('Choose both a latitude and a longitude column, or neither.');
  }

  if (count('latitude') && count('geometry')) {
    problems.push('Use coordinate columns or a geometry column, not both.');
  }

  const fields = _.filter(columns, (c) => c.role === 'field');

  if (_.some(fields, (c) => !c.label?.trim())) {
    problems.push('Every field needs a name.');
  }

  const labels = _.map(fields, (c) => c.label?.trim().toLowerCase());

  if (_.uniq(labels).length < labels.length) {
    problems.push('Two fields have the same name.');
  }

  return problems;
};

/**
 * Upload a curator's own dataset: pick a CSV or GeoJSON file, review how each
 * column will be used and where the rows fall on the map, then import it as
 * places. Nothing is written until Import is pressed.
 */
const DatasetImportPanel = ({ onImported, projectId }) => {
  const [file, setFile] = useState(null);
  const [preview, setPreview] = useState(null);
  const [columns, setColumns] = useState([]);
  const [loading, setLoading] = useState(false);
  const [jobId, setJobId] = useState(null);
  const [result, setResult] = useState(null);
  const [errors, setErrors] = useState([]);
  const [geocodeConfig, setGeocodeConfig] = useState({});
  const [geocodeResult, setGeocodeResult] = useState(null);
  const [useGeocode, setUseGeocode] = useState(false);
  // A KML's image overlays become map layers (untick to leave them out).
  const [addOverlays, setAddOverlays] = useState(true);

  const job = useJobPolling(jobId);
  const importing = !!jobId;

  const problems = useMemo(() => validate(columns), [columns]);

  const onChooseFile = useCallback((event) => {
    setFile(event.target.files?.[0] || null);
    setPreview(null);
    setResult(null);
    setErrors([]);
  }, []);

  const onPreview = useCallback(() => {
    setLoading(true);
    setErrors([]);
    setResult(null);

    setGeocodeResult(null);
    setUseGeocode(false);

    previewDatasetImport(projectId, file)
      .then((data) => {
        setPreview(data.dataset_import);
        setGeocodeConfig({ ...(data.dataset_import.geocoding?.suggested || {}) });
        setColumns(data.dataset_import.previous_import
          ? withPreviousChoices(data.dataset_import.columns)
          : _.map(data.dataset_import.columns, (column) => ({ ...column })));
      })
      .catch((error) => {
        setPreview(null);
        setErrors(errorMessages(error));
      })
      .finally(() => setLoading(false));
  }, [file, projectId]);

  const updateColumn = useCallback((name, changes) => {
    setColumns((prev) => _.map(prev, (column) => {
      if (column.name === name) {
        // Renaming re-checks whether the name fills an existing field (and
        // so takes its type) or makes a new one.
        if ('label' in changes) {
          const field = _.find(preview?.existing_fields, (f) => fieldKey(f.label) === fieldKey(changes.label));
          const base = _.omit(column, 'existing', 'field_uuid');

          if (field) {
            return { ...base, ...changes, existing: true, field_uuid: field.uuid, data_type: field.data_type };
          }

          // Leaving an existing field: back to the type the values suggest.
          return column.existing
            ? { ...base, ...changes, data_type: column.inferred_type || column.data_type }
            : { ...base, ...changes };
        }

        return { ...column, ...changes };
      }

      // A single-use role moves off whichever column had it: a former name
      // column is still data (a field); a former identifier or coordinate
      // column isn't worth showing, so it isn't imported.
      if (changes.role && _.contains(SINGLE_ROLES, changes.role) && column.role === changes.role) {
        return { ...column, role: changes.role === 'name' ? 'field' : 'skip' };
      }

      return column;
    }));
  }, [preview]);

  const onImport = useCallback(() => {
    setErrors([]);

    createDatasetImport(projectId, {
      blob_id: preview.blob_id,
      project_model_id: preview.project_model_id,
      columns: _.map(columns, (c) => _.pick(c, 'name', 'role', 'label', 'data_type', 'capitalize', 'copy')),
      geocode: useGeocode && geocodeResult ? _.pick(geocodeConfig, (value) => value === true || (_.isString(value) && value !== '')) : undefined,
      overlays: _.some(preview.overlays, (o) => o.usable) ? addOverlays : undefined
    })
      .then((data) => setJobId(data.job.id))
      .catch((error) => setErrors(errorMessages(error)));
  }, [addOverlays, columns, geocodeConfig, geocodeResult, preview, projectId, useGeocode]);

  useEffect(() => {
    if (!job || !isTerminal(job.status)) {
      return;
    }

    setResult(job);
    setJobId(null);

    if (job.status === JobStatuses.completed && onImported) {
      onImported();
    }
  }, [job, onImported]);

  const geometryCounts = preview?.geometry?.counts || {};
  const located = _.reduce(_.omit(geometryCounts, 'missing', 'invalid'), (sum, n) => sum + n, 0);

  // Places found from their address join the preview map, and count as
  // placed in the warning before import.
  const lookupFeatures = useMemo(() => {
    if (!useGeocode || !geocodeResult) {
      return [];
    }

    const features = geocodeResult.features.features;
    return geocodeConfig.exact_only ? _.filter(features, (f) => f.properties.status === 'exact') : features;
  }, [geocodeConfig.exact_only, geocodeResult, useGeocode]);
  const mapData = useMemo(() => preview && ({
    type: 'FeatureCollection',
    features: [...(preview.geometry?.features?.features || []), ...lookupFeatures]
  }), [preview, lookupFeatures]);
  const mapBbox = useMemo(() => {
    const points = _.flatten(_.map(lookupFeatures, (f) => [f.geometry.coordinates]), true);
    const base = preview?.geometry?.bbox;

    return _.reduce(points, (box, [lon, lat]) => (box
      ? [Math.min(box[0], lon), Math.min(box[1], lat), Math.max(box[2], lon), Math.max(box[3], lat)]
      : [lon, lat, lon, lat]), base);
  }, [preview, lookupFeatures]);
  const unplaced = (geometryCounts.missing || 0) - lookupFeatures.length;

  // Bulk choices for wide files (a GIS export can have dozens of columns):
  // skip every column still set to Field, then turn on the ones wanted; or
  // go back to the preview's suggestions.
  const skipAllFields = () => setColumns((prev) => _.map(prev, (c) => (c.role === 'field' ? { ...c, role: 'skip' } : c)));
  const restoreSuggestions = () => setColumns(_.map(preview.columns, (c) => ({ ...c })));
  const usePreviousChoices = () => setColumns(withPreviousChoices(preview.columns));
  const previousImport = preview?.previous_import;
  const fieldCount = _.filter(columns, (c) => c.role === 'field').length;

  /**
   * What the chosen type will do with this column's values: a warning when
   * some can't be read as that type (they'd be left empty), or how a
   * checkmark column reads.
   */
  const renderTypeNote = (column) => {
    const misfit = column.misfits?.[column.data_type];

    if (misfit) {
      const kind = TYPE_VALUES[column.data_type];
      const message = misfit.count >= column.filled
        ? `None of these values are ${kind} (e.g. “${misfit.example}”), so they would all be left empty.`
        : `${misfit.count} of ${column.filled} values aren’t ${kind} (e.g. “${misfit.example}”) and would be left empty.`;

      // An existing field's type is fixed here; the way out is a new field.
      const advice = column.existing
        ? `“${column.label}” is an existing field of that type: give the column a new field name to make a new field instead.`
        : 'Try another type, or Short text.';

      return <div className='column-warning'>{ message } { advice }</div>;
    }

    if (column.data_type === 'Boolean' && column.checkmarks) {
      return <div className='muted column-note'>Marked rows are Yes; blank rows are No.</div>;
    }

    return null;
  };

  const renderColumn = (column) => {
    const keeps = column.role === 'field' || column.role === 'identifier' || column.role === 'photo';

    const typeNote = column.role === 'field' ? renderTypeNote(column) : null;

    return (
      <Fragment key={column.name}>
        <tr className={typeNote ? 'has-note' : undefined}>
          <td>
            <strong>{ column.name }</strong>
            <div className='muted'>{ column.filled } of { preview.row_count } filled</div>
            { column.note && column.role === 'skip' && <div className='muted column-note'>{ column.note }</div> }
            { column.identifier_note && column.role === 'identifier' && <div className='muted column-note'>{ column.identifier_note }</div> }
            { column.role === 'photo' && preview.photo_server && (
              <>
                <label className='column-option'>
                  <input
                    checked={column.copy !== false}
                    onChange={(e) => updateColumn(column.name, { copy: e.target.checked })}
                    type='checkbox'
                  />
                  Copy the photos to the atlas’s image server
                </label>
                <div className='muted column-note'>
                  Kept on { preview.photo_server } with sizes for every screen, and shown on result cards. Copy them
                  when you may reuse them (public domain, your own, or licensed); unticked, they’re shown from the source.
                </div>
              </>
            )}
            { column.role === 'types' && column.capitalize_example && (
              <label className='column-option'>
                <input
                  checked={!!column.capitalize}
                  onChange={(e) => updateColumn(column.name, { capitalize: e.target.checked })}
                  type='checkbox'
                />
                Capitalize: { column.capitalize_example[0] } → { column.capitalize_example[1] }
              </label>
            )}
            { column.role === 'types' && column.capitalize_example && column.terms > column.capitalize_terms && (
              <div className='muted column-note'>
                { column.capitalize_terms } of { column.terms } terms are in lower case; the ones with capitals stay as written.
              </div>
            )}
            { column.role === 'identifier' && column.duplicates > 0 && (
              <div className='column-warning'>
                { column.duplicates } { column.duplicates === 1 ? 'row repeats' : 'rows repeat' } another row’s value.
                They’re all imported, but a later import treats any row with one of these values as already imported.
              </div>
            )}
          </td>
          <td className='muted'>{ _.map(column.samples, (sample) => sample.length > 60 ? `${sample.slice(0, 60)}…` : sample).join(' · ') }</td>
          <td>
            <Select
              onChange={(role) => updateColumn(column.name, { role })}
              options={ROLES}
              placeholder='Choose…'
              value={column.role}
            />
          </td>
          <td>
            { keeps && (
              <input
                aria-label={`Field name for ${column.name}`}
                className='input'
                onChange={(e) => updateColumn(column.name, { label: e.target.value })}
                value={column.label || ''}
              />
            )}
            { keeps && column.existing && <div className='muted'>Fills the existing field</div> }
          </td>
          <td>
            { column.role === 'field' && (
              <Select
                disabled={column.existing}
                onChange={(data_type) => updateColumn(column.name, { data_type })}
                options={TYPES}
                placeholder='Choose…'
                value={column.data_type}
              />
            )}
          </td>
        </tr>
        { typeNote && (
          <tr className='column-note-row'>
            <td colSpan={5}>{ typeNote }</td>
          </tr>
        )}
      </Fragment>
    );
  };

  const renderResult = () => {
    const {
      counts = {},
      error,
      fields_created: created,
      filters_added: filters,
      searched_fields: searched,
      dates_added: dated,
      hidden_fields: hidden,
      problems: rowProblems,
      geocode_error: geocodeError,
      overlays_added: overlaysAdded,
      overlay_problems: overlayProblems
    } = result.extra || {};

    return (
      <div className='card'>
        <h2 className='h-sub'>{ result.extra?.filename } <JobStatus status={result.status} /></h2>
        { error && <Message action={<FeedbackLink error={error} jobId={result.id} />} tone='negative'>{ error }</Message> }
        { result.status === JobStatuses.completed && (
          <div className='stats'>
            <Stat label='Imported' tone='positive' value={counts.imported || 0} />
            { counts.skipped > 0 && <Stat label='Already in the atlas' value={counts.skipped} /> }
            { counts.shared_identifier > 0 && <Stat label='Shared an identifier' value={counts.shared_identifier} /> }
            { counts.located_from_address > 0 && <Stat label='Placed from an address' value={counts.located_from_address} /> }
            { counts.without_geometry > 0 && <Stat label='No location' value={counts.without_geometry} /> }
            { counts.failed > 0 && <Stat label='Failed' tone='negative' value={counts.failed} /> }
          </div>
        )}
        { geocodeError && <Message tone='warning'>{ geocodeError }</Message> }
        { !_.isEmpty(created) && <p className='muted'>New fields: { created.join(', ') }</p> }
        { !_.isEmpty(filters) && <p className='muted'>Added as filters on the atlas: { filters.join(', ') }</p> }
        { !_.isEmpty(searched) && <p className='muted'>The atlas’s search now also looks in: { searched.join(', ') }</p> }
        { !_.isEmpty(dated) && <p className='muted'>Visitors can now filter and sort by: { dated.join(', ') } (change in Settings → Search → Time)</p> }
        { !_.isEmpty(hidden) && <p className='muted'>Hidden on public pages: { hidden.join(', ') } (change in Settings → Detail pages)</p> }
        { !_.isEmpty(overlaysAdded) && <p className='muted'>Added to the map layers: { overlaysAdded.join(', ') } (change in Settings → Map layers)</p> }
        { !_.isEmpty(overlayProblems) && (
          <Message header='Image overlays not added' list={_.map(overlayProblems, (p) => `${p.name}: ${p.message}`)} tone='warning' />
        )}
        { !_.isEmpty(rowProblems) && <Message header='Rows to check' list={rowProblems} tone='warning' /> }
        { result.status === JobStatuses.completed && counts.imported > 0 && (
          result.extra?.reindex_job_id
            ? <ReindexStatus jobId={result.extra.reindex_job_id} />
            : <Message tone='positive'>Imported. The places appear on the atlas as soon as the reindex finishes.</Message>
        )}
        { result.status === JobStatuses.completed && <CopyPhotosStatus jobId={result.extra?.copy_photos_job_id} /> }
      </div>
    );
  };

  return (
    <div className='import-panel'>
      <p className='muted'>
        A spreadsheet (Excel .xlsx, OpenDocument .ods, or CSV or tab-separated text: .csv, .tsv, .txt), a
        GeoJSON file (.geojson or .json), a Google Earth or My Maps file (.kml or .kmz), or a shapefile
        zipped with its .dbf and .prj; up to 50 MB, 50,000 rows and 500 columns. Nothing is imported until you review
        it and press Import.
      </p>

      { !_.isEmpty(errors) && <Message action={<FeedbackLink error={errors} />} list={errors} tone='negative' /> }

      <div className='card'>
        <input accept={ACCEPT} aria-label='Dataset file' onChange={onChooseFile} type='file' />
        <div className='actions'>
          <Button disabled={!file || importing} loading={loading} onClick={onPreview}>Preview</Button>
        </div>
      </div>

      { preview && (
        <div className='card'>
          <h2 className='h-sub'>{ preview.filename }</h2>
          <div className='stats'>
            <Stat label='Rows' value={preview.row_count} />
            { _.map(_.omit(geometryCounts, 'missing', 'invalid'), (n, type) => (
              <Stat key={type} label={GEOMETRY_LABELS[type] || type} value={n} />
            ))}
            { geometryCounts.missing > 0 && <Stat label='No location' value={geometryCounts.missing} /> }
            { geometryCounts.invalid > 0 && <Stat label='Unusable location' tone='negative' value={geometryCounts.invalid} /> }
          </div>
          { !_.isEmpty(preview.warnings) && <Message list={preview.warnings} tone='warning' /> }
          { _.some(preview.overlays, (o) => o.usable) && (
            <div className='field'>
              <label className='check'>
                <input checked={addOverlays} onChange={(e) => setAddOverlays(e.target.checked)} type='checkbox' />
                Add the image overlays to the atlas’s map layers
              </label>
              <span className='field-hint'>
                { _.map(_.filter(preview.overlays, (o) => o.usable), (o) => (o.start_year ? `${o.name} (${o.start_year})` : o.name)).join(', ') }:
                each image is stored with the atlas’s images and laid on the map where the file puts it. Visitors can show it
                and fade it from the map’s layers button; dated ones join the year slider.
              </span>
            </div>
          )}
          { !_.isEmpty(preview.geometry?.problems) && (
            <Message header='Rows whose location can’t be used (they import without one)' list={preview.geometry.problems} tone='warning' />
          )}

          { located + lookupFeatures.length > 0 && (
            <>
              <p className='muted'>
                Showing { preview.geometry.features.features.length } of { located } located rows
                { lookupFeatures.length > 0 && <>, and { lookupFeatures.length } found from their address (orange)</> }
              </p>
              <Suspense fallback={<div className='preview-map muted' style={{ height: 420 }}>Loading map…</div>}>
                <PreviewMap bbox={mapBbox} data={mapData} />
              </Suspense>
            </>
          )}
          { located === 0 && !preview.geocoding && (
            <Message tone='warning'>
              No column was recognized as a location. Set a latitude and a longitude column, or a geometry column, below.
            </Message>
          )}
          { preview.geocoding && (
            <AddressLookup
              blobId={preview.blob_id}
              columns={columns}
              config={geocodeConfig}
              missing={geometryCounts.missing}
              onConfigChange={setGeocodeConfig}
              onResult={setGeocodeResult}
              onUseChange={setUseGeocode}
              projectId={projectId}
              provider={preview.geocoding.provider}
              result={geocodeResult}
              use={useGeocode}
            />
          )}

          <h3 className='h-sub'>Columns</h3>
          <p className='muted'>
            Each row becomes a place in { preview.project_model_name }. A <strong>Category</strong> column becomes the
            atlas’s place-type filter (separate several values with “;”). An <strong>Identifier</strong> is a unique id
            from your source: importing again later skips rows whose id is already in the atlas. A <strong>Photo</strong>
            column of image addresses is shown as each place’s picture.
            A <strong>Geometry</strong> column holds WKT or GeoJSON shapes. Columns that look like file bookkeeping start as “Don’t import”.
          </p>
          { previousImport && (
            <Message tone='info'>
              Using your choices from the last upload, { previousImport.filename } ({ new Date(previousImport.imported_at).toLocaleDateString() }),
              for the { previousImport.matched } { previousImport.matched === 1 ? 'column' : 'columns' } this file shares with it.
            </Message>
          )}
          <div className='row column-actions'>
            <Button disabled={fieldCount === 0} onClick={skipAllFields} subtle>Skip all fields ({ fieldCount })</Button>
            <Button onClick={restoreSuggestions} subtle>Restore suggestions</Button>
            { previousImport && <Button onClick={usePreviousChoices} subtle>Use last upload’s choices</Button> }
            <span className='muted'>Then set the columns you want back to Field.</span>
          </div>
          <div className='scroll-x'>
            <div className='table-scroll'>
              <table className='table'>
                <thead>
                  <tr>
                    <th>Column</th>
                    <th>Examples</th>
                    <th>Use as</th>
                    <th>Field name</th>
                    <th>Type</th>
                  </tr>
                </thead>
                <tbody>
                  { _.map(columns, renderColumn) }
                </tbody>
              </table>
            </div>
          </div>

          { !_.isEmpty(problems) && <Message list={problems} tone='warning' /> }
          { unplaced > 0 && (
            <Message tone='warning'>
              { unplaced } { unplaced === 1 ? 'place' : 'places' } will have no location: listed and searchable on the
              atlas, but not on the map.
            </Message>
          )}

          <div className='actions'>
            <Button disabled={!_.isEmpty(problems) || importing} loading={importing} onClick={onImport} primary>
              Import { preview.row_count } rows
            </Button>
          </div>
        </div>
      )}

      { importing && (
        <div className='card'>
          <Message>Importing { preview?.filename }…</Message>
          { job?.extra?.progress && <Progress total={job.extra.progress.total} value={job.extra.progress.completed} /> }
        </div>
      )}

      { result && renderResult() }
    </div>
  );
};

export default DatasetImportPanel;
