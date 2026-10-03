import _ from 'underscore';
import { Button, Field, Message, MultiSelect, Toggle } from './ui';

const MAX_DEPTH = 3;

const replaceAt = (list, index, value) => list.map((item, i) => (i === index ? value : item));

const move = (list, index, delta) => {
  const target = index + delta;
  if (target < 0 || target >= list.length) return list;

  const next = [...list];
  [next[index], next[target]] = [next[target], next[index]];
  return next;
};

/**
 * One group of the tree: its name, its categories, and its own subgroups
 * (three levels at most). Headings follow the level, as the page's do.
 */
const GroupEditor = ({ depth, group, index, count, onChange, onMove, onRemove, terms }) => {
  const groups = group.groups || [];
  const Heading = `h${Math.min(depth + 2, 6)}`;

  return (
    <div className='card topic-group'>
      <div className='section-head'>
        <Heading className='h-sub'>{ group.label || (depth === 1 ? 'New group' : 'New subgroup') }</Heading>
        <div className='section-controls'>
          <Button aria-label={`Move “${group.label || 'group'}” up`} disabled={index === 0} onClick={() => onMove(-1)} subtle>↑</Button>
          <Button aria-label={`Move “${group.label || 'group'}” down`} disabled={index === count - 1} onClick={() => onMove(1)} subtle>↓</Button>
          <Button onClick={onRemove} subtle>Remove</Button>
        </div>
      </div>
      <Field label='Name'>
        <input className='input' maxLength={100} onChange={(e) => onChange({ ...group, label: e.target.value })} value={group.label || ''} />
      </Field>
      <Field label='Categories in it'>
        <MultiSelect
          onChange={(value) => onChange({ ...group, terms: value })}
          options={_.map(terms, (term) => ({ value: term, text: term }))}
          value={group.terms || []}
        />
      </Field>
      { _.map(groups, (child, i) => (
        <GroupEditor
          count={groups.length}
          depth={depth + 1}
          group={child}
          index={i}
          key={i}
          onChange={(value) => onChange({ ...group, groups: replaceAt(groups, i, value) })}
          onMove={(delta) => onChange({ ...group, groups: move(groups, i, delta) })}
          onRemove={() => onChange({ ...group, groups: _.reject(groups, (c, j) => j === i) })}
          terms={terms}
        />
      ))}
      { depth < MAX_DEPTH && (
        <Button onClick={() => onChange({ ...group, groups: [...groups, { label: '', terms: [], groups: [] }] })} subtle>+ Add a subgroup</Button>
      )}
    </div>
  );
};

const groupedTerms = (groups) => _.flatten(_.map(groups || [], (group) => [...(group.terms || []), ...groupedTerms(group.groups)]));

/**
 * Settings → Topics: the atlas's categories as pages — a Topics page that
 * lays them out as a tree of the curator's groups (the rest listed after),
 * and a page per category with its places (config.topics).
 */
const TopicsEditor = ({ categories, menuHasTopics, menuCustomized, onAddToMenu, onChange, pageHref, topics }) => {
  const value = topics || {};
  const groups = value.groups || [];
  const terms = _.pluck(categories?.terms || [], 'name');
  const ungrouped = _.difference(terms, groupedTerms(groups));

  return (
    <>
      <p className='muted'>
        The atlas’s categories{ categories?.name ? ` (${categories.name})` : '' } as pages of their own: a <strong>Topics</strong> page that
        shows them as a tree — your groups first, then any category in no group — and a page for each category with its places on a map.
        Category names on place pages link to them.
      </p>
      <Toggle checked={value.enabled === true} label='Show a Topics page' onChange={(enabled) => onChange({ ...value, enabled })} />
      { value.enabled && pageHref && <p><a href={pageHref} rel='noreferrer' target='_blank'>Open the Topics page ↗</a> (after saving)</p> }
      { value.enabled && menuCustomized && !menuHasTopics && (
        <Message action={<Button onClick={onAddToMenu}>Add Topics to the menu</Button>} tone='info'>
          Your menu is customized, so Topics isn’t in it yet.
        </Message>
      )}
      <div className='grid-2'>
        <Field hint='The page’s title and its name in the menu.' label='Title'>
          <input className='input' maxLength={100} onChange={(e) => onChange({ ...value, title: e.target.value || undefined })} placeholder='Topics' value={value.title || ''} />
        </Field>
        <Field hint='A sentence or two above the tree.' label='Introduction'>
          <textarea className='input' maxLength={1000} onChange={(e) => onChange({ ...value, intro: e.target.value || undefined })} rows={3} value={value.intro || ''} />
        </Field>
      </div>
      <h2 className='h-section'>Groups</h2>
      { _.isEmpty(terms) && <Message>This atlas has no categories yet. They come from an upload’s Category column, or the Types in FairData.</Message> }
      { _.map(groups, (group, i) => (
        <GroupEditor
          count={groups.length}
          depth={1}
          group={group}
          index={i}
          key={i}
          onChange={(next) => onChange({ ...value, groups: replaceAt(groups, i, next) })}
          onMove={(delta) => onChange({ ...value, groups: move(groups, i, delta) })}
          onRemove={() => onChange({ ...value, groups: _.reject(groups, (g, j) => j === i) })}
          terms={terms}
        />
      ))}
      <Button onClick={() => onChange({ ...value, groups: [...groups, { label: '', terms: [], groups: [] }] })} subtle>+ Add a group</Button>
      { !_.isEmpty(ungrouped) && (
        <p className='muted'>In no group (listed after the groups): { ungrouped.join(', ') }</p>
      )}
    </>
  );
};

export default TopicsEditor;
