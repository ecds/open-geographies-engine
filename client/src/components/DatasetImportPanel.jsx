import {
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
import JobStatus from './JobStatus';
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

const ACCEPT = '.csv,.tsv,.txt,.xlsx,.ods,.geojson,.json,.zip';

const ROLES = [
  { value: 'name', text: 'Place name' },
  { value: 'field', text: 'Field' },
  { value: 'types', text: 'Category' },
  { value: 'latitude', text: 'Latitude' },
  { value: 'longitude', text: 'Longitude' },
  { value: 'geometry', text: 'Geometry' },
  { value: 'identifier', text: 'Identifier' },
  { value: 'skip', text: 'Don\u2019t import' }
];

// Roles a file can have at most one of; choosing one moves it off the
// column that had it.
const SINGLE_ROLES = ['name', 'latitude', 'longitude', 'geometry', 'identifier'];

const TYPES = [
  { value: 'String', text: 'Short text' },
  { value: 'Text', text: 'Long text' },
  { value: 'Select', text: 'Pick-list (filterable)' },
  { value: 'Number', text: 'Number' },
  { value: 'Boolean', text: 'Yes / No' },
  { value: 'Date', text: 'Date (YYYY-MM-DD)' }
];

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

    previewDatasetImport(projectId, file)
      .then((data) => {
        setPreview(data.dataset_import);
        setColumns(_.map(data.dataset_import.columns, (column) => ({ ...column })));
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
  }, []);

  const onImport = useCallback(() => {
    setErrors([]);

    createDatasetImport(projectId, {
      blob_id: preview.blob_id,
      project_model_id: preview.project_model_id,
      columns: _.map(columns, (c) => _.pick(c, 'name', 'role', 'label', 'data_type'))
    })
      .then((data) => setJobId(data.job.id))
      .catch((error) => setErrors(errorMessages(error)));
  }, [columns, preview, projectId]);

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

  // Bulk choices for wide files (a GIS export can have dozens of columns):
  // skip every column still set to Field, then turn on the ones wanted; or
  // go back to the preview's suggestions.
  const skipAllFields = () => setColumns((prev) => _.map(prev, (c) => (c.role === 'field' ? { ...c, role: 'skip' } : c)));
  const restoreSuggestions = () => setColumns(_.map(preview.columns, (c) => ({ ...c })));
  const fieldCount = _.filter(columns, (c) => c.role === 'field').length;

  const renderColumn = (column) => {
    const keeps = column.role === 'field' || column.role === 'identifier';

    return (
      <tr key={column.name}>
        <td>
          <strong>{ column.name }</strong>
          <div className='muted'>{ column.filled } of { preview.row_count } filled</div>
          { column.note && column.role === 'skip' && <div className='muted column-note'>{ column.note }</div> }
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
              disabled={column.existing}
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
    );
  };

  const renderResult = () => {
    const {
      counts = {},
      error,
      fields_created: created,
      filters_added: filters,
      hidden_fields: hidden,
      problems: rowProblems
    } = result.extra || {};

    return (
      <div className='card'>
        <h4>{ result.extra?.filename } <JobStatus status={result.status} /></h4>
        { error && <Message tone='negative'>{ error }</Message> }
        { result.status === JobStatuses.completed && (
          <div className='stats'>
            <Stat label='Imported' tone='positive' value={counts.imported || 0} />
            { counts.skipped > 0 && <Stat label='Already in the atlas' value={counts.skipped} /> }
            { counts.shared_identifier > 0 && <Stat label='Shared an identifier' value={counts.shared_identifier} /> }
            { counts.without_geometry > 0 && <Stat label='No location' value={counts.without_geometry} /> }
            { counts.failed > 0 && <Stat label='Failed' tone='negative' value={counts.failed} /> }
          </div>
        )}
        { !_.isEmpty(created) && <p className='muted'>New fields: { created.join(', ') }</p> }
        { !_.isEmpty(filters) && <p className='muted'>Added as filters on the atlas: { filters.join(', ') }</p> }
        { !_.isEmpty(hidden) && <p className='muted'>Hidden on public pages: { hidden.join(', ') } (change in Settings → Detail pages)</p> }
        { !_.isEmpty(rowProblems) && <Message header='Rows to check' list={rowProblems} tone='warning' /> }
        { result.status === JobStatuses.completed && counts.imported > 0 && (
          <Message tone='positive'>Imported. The places appear on the atlas as soon as the reindex finishes.</Message>
        )}
      </div>
    );
  };

  return (
    <div className='import-panel'>
      <p className='muted'>
        A spreadsheet (Excel .xlsx, OpenDocument .ods, or CSV), a GeoJSON file, or a shapefile zipped
        with its .dbf and .prj. Nothing is imported until you review it and press Import.
      </p>

      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }

      <div className='card'>
        <input accept={ACCEPT} aria-label='Dataset file' onChange={onChooseFile} type='file' />
        <div className='actions'>
          <Button disabled={!file || importing} loading={loading} onClick={onPreview}>Preview</Button>
        </div>
      </div>

      { preview && (
        <div className='card'>
          <h4>{ preview.filename }</h4>
          <div className='stats'>
            <Stat label='Rows' value={preview.row_count} />
            { _.map(_.omit(geometryCounts, 'missing', 'invalid'), (n, type) => (
              <Stat key={type} label={GEOMETRY_LABELS[type] || type} value={n} />
            ))}
            { geometryCounts.missing > 0 && <Stat label='No location' value={geometryCounts.missing} /> }
            { geometryCounts.invalid > 0 && <Stat label='Unusable location' tone='negative' value={geometryCounts.invalid} /> }
          </div>
          { !_.isEmpty(preview.warnings) && <Message list={preview.warnings} tone='warning' /> }
          { !_.isEmpty(preview.geometry?.problems) && (
            <Message header='Rows whose location can’t be used (they import without one)' list={preview.geometry.problems} tone='warning' />
          )}

          { located > 0 && (
            <>
              <p className='muted'>
                Showing { preview.geometry.features.features.length } of { located } located rows
              </p>
              <Suspense fallback={<div className='preview-map muted' style={{ height: 420 }}>Loading map…</div>}>
                <PreviewMap bbox={preview.geometry.bbox} data={preview.geometry.features} />
              </Suspense>
            </>
          )}
          { located === 0 && (
            <Message tone='warning'>
              No column was recognized as a location. Set a latitude and a longitude column, or a geometry column, below.
            </Message>
          )}

          <h4>Columns</h4>
          <p className='muted'>
            Each row becomes a place in { preview.project_model_name }. A <strong>Category</strong> column becomes the
            atlas’s place-type filter (separate several values with “;”). An <strong>Identifier</strong> is a unique id
            from your source: importing again later skips rows whose id is already in the atlas. A <strong>Geometry</strong>
            column holds WKT or GeoJSON shapes. Columns that look like file bookkeeping start as “Don’t import”.
          </p>
          <div className='row column-actions'>
            <Button disabled={fieldCount === 0} onClick={skipAllFields} subtle>Skip all fields ({ fieldCount })</Button>
            <Button onClick={restoreSuggestions} subtle>Restore suggestions</Button>
            <span className='muted'>Then set the columns you want back to Field.</span>
          </div>
          <div className='scroll-x'>
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

          { !_.isEmpty(problems) && <Message list={problems} tone='warning' /> }

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
