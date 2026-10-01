import { useCallback, useEffect, useMemo, useState } from 'react';
import _ from 'underscore';
import { errorMessages, fetchCategories, renameCategoryValue } from '../api';
import { Button, Message } from './ui';

// Lists longer than this get a filter box.
const FILTER_AT = 15;

const fold = (value) => value.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();

/**
 * One category value, renamable in place. A name another value already has
 * merges the two, said before saving.
 */
const ValueRow = ({ onRename, others, term }) => {
  const [name, setName] = useState(term.name);
  const [saving, setSaving] = useState(false);

  useEffect(() => setName(term.name), [term.name]);

  const trimmed = name.replace(/\s+/g, ' ').trim();
  const changed = trimmed !== term.name && trimmed !== '';
  const target = changed ? _.find(others, (other) => other.name.toLowerCase() === trimmed.toLowerCase()) : null;

  const save = () => {
    if (!changed) {
      return;
    }

    setSaving(true);
    onRename(term, trimmed).finally(() => setSaving(false));
  };

  return (
    <tr>
      <td>
        <input
          aria-label={`Rename “${term.name}”`}
          className='input'
          maxLength={255}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') save(); if (e.key === 'Escape') setName(term.name); }}
          value={name}
        />
        { target && (
          <div className='column-warning'>
            “{ target.name }” already exists ({ target.places } { target.places === 1 ? 'place' : 'places' }): saving merges the two.
          </div>
        )}
      </td>
      <td className='numeric'>{ term.places }</td>
      <td className='table-actions'>
        { changed && (
          <>
            <Button loading={saving} onClick={save} primary>{ target ? 'Merge' : 'Rename' }</Button>
            <Button disabled={saving} onClick={() => setName(term.name)} subtle>Cancel</Button>
          </>
        )}
      </td>
    </tr>
  );
};

/**
 * The atlas's category values (each taxonomy its places use: Types, and
 * any others), renamable after import. The new name shows everywhere on
 * the atlas — filter, result cards, place pages — once the places are
 * reindexed, within a minute or so.
 */
const CategoryValues = ({ site }) => {
  const [categories, setCategories] = useState(null);
  const [errors, setErrors] = useState([]);
  const [notice, setNotice] = useState(null);
  const [filters, setFilters] = useState({});

  const load = useCallback(() => (
    fetchCategories(site.id)
      .then((data) => setCategories(data.categories || []))
      .catch((error) => setErrors(errorMessages(error)))
  ), [site.id]);

  useEffect(() => { load(); }, [load]);

  const onRename = (term, name) => {
    setErrors([]);
    setNotice(null);

    return renameCategoryValue(site.id, term.id, name)
      .then((data) => {
        setNotice(data.merged
          ? `“${term.name}” is merged into “${data.term.name}” (${data.term.places} ${data.term.places === 1 ? 'place' : 'places'}).`
          : `“${term.name}” is now “${data.term.name}”.`);
        return load();
      })
      .catch((error) => setErrors(errorMessages(error)));
  };

  const visible = useMemo(() => _.object(_.map(categories || [], (category) => {
    const needle = fold((filters[category.id] || '').trim());
    return [category.id, needle ? _.filter(category.terms, (term) => fold(term.name).includes(needle)) : category.terms];
  })), [categories, filters]);

  if (!categories) {
    return <>{ !_.isEmpty(errors) ? <Message list={errors} tone='negative' /> : <p className='muted'>Loading…</p> }</>;
  }

  if (_.isEmpty(categories)) {
    return <Message>This atlas’s places have no categories yet. An upload’s Category column creates them.</Message>;
  }

  return (
    <div className='category-values'>
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      { notice && <Message tone='positive'>{ notice } The atlas shows the change within a minute or so.</Message> }
      <p className='muted'>
        Rename a value to fix its spelling or wording; the atlas’s filter, result cards and place pages follow. Renaming
        it to a name another value has merges the two.
      </p>
      { _.map(categories, (category) => (
        <section key={category.id}>
          <h3>{ category.name } <span className='muted'>({ category.terms.length })</span></h3>
          { category.terms.length > FILTER_AT && (
            <input
              aria-label={`Find in ${category.name}`}
              className='input category-filter'
              onChange={(e) => setFilters({ ...filters, [category.id]: e.target.value })}
              placeholder={`Find in ${category.name}`}
              value={filters[category.id] || ''}
            />
          )}
          <table className='table'>
            <thead>
              <tr><th>Value</th><th className='numeric'>Places</th><th /></tr>
            </thead>
            <tbody>
              { _.map(visible[category.id], (term) => (
                <ValueRow key={term.id} onRename={onRename} others={_.without(category.terms, term)} term={term} />
              ))}
            </tbody>
          </table>
          { _.isEmpty(visible[category.id]) && <p className='muted'>Nothing matches.</p> }
        </section>
      ))}
    </div>
  );
};

export default CategoryValues;
