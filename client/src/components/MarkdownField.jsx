import { micromark } from 'micromark';
import { gfm, gfmHtml } from 'micromark-extension-gfm';
import { useContext, useLayoutEffect, useMemo, useRef, useState } from 'react';
import _ from 'underscore';
import ImageCropper, { ImageCropContext } from './ImageCropper';
import { AssetPicker, cropTargetFor } from './ImageField';
import { Button } from './ui';

// ![description](address "optional title")
const IMAGE = /!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;

/**
 * Page text in Markdown: a textarea with a small formatting toolbar and a
 * preview. The preview uses micromark as the atlas does (raw HTML escaped,
 * unsafe link schemes dropped), so what the curator sees is what renders —
 * apart from the atlas's own fonts and colors.
 */
const MarkdownField = ({ assets, hint, label, onChange, onUpload, rows = 8, value }) => {
  const [preview, setPreview] = useState(false);
  const [picking, setPicking] = useState(false);
  const [cropping, setCropping] = useState(null);
  const cropAsset = useContext(ImageCropContext);
  const textarea = useRef();

  // The uploaded images this text shows, each croppable as in an image
  // field; the crop's new address replaces the old one in the text.
  const images = useMemo(() => {
    if (!cropAsset) return [];

    const found = _.uniq([...(value || '').matchAll(IMAGE)].map((match) => ({ alt: match[1], path: match[2] })), false, (image) => image.path);
    return _.compact(_.map(found, ({ alt, path }) => {
      const asset = _.findWhere(assets, { path });
      const target = asset && cropTargetFor(asset, assets);
      return target && { alt, asset, path, target };
    }));
  }, [assets, cropAsset, value]);

  // The new address in place of the old; focus goes back to the text with
  // the image's markup selected (the Crop… button that opened the cropper
  // belonged to the old address and is gone).
  const onCropped = (asset) => {
    const next = (value || '').split(`](${cropping.path}`).join(`](${asset.path}`);
    const at = next.indexOf(`](${asset.path}`);
    const start = next.lastIndexOf('![', at);

    if (at >= 0 && start >= 0) {
      pendingSelection.current = [start, next.indexOf(')', at + 2 + asset.path.length) + 1];
    }

    onChange(next);
    setCropping(null);
  };

  // The selection to restore once an edit has rendered. Restored in a layout
  // effect (right after React writes the new value, before anything else can
  // happen) so typing straight after a toolbar click lands in the selection.
  const pendingSelection = useRef(null);

  useLayoutEffect(() => {
    const element = textarea.current;

    if (element && pendingSelection.current) {
      element.focus();
      element.setSelectionRange(...pendingSelection.current);
      pendingSelection.current = null;
    }
  }, [value]);

  // Toolbar buttons don't take focus from the text.
  const keepFocus = (e) => e.preventDefault();

  const html = useMemo(() => (preview ? micromark(value || '', {
    extensions: [gfm()],
    htmlExtensions: [gfmHtml()]
  }) : ''), [preview, value]);

  /**
   * Wraps the selection (or inserts a placeholder) and selects the part the
   * curator will want to type over.
   */
  const edit = (before, after = '', placeholder = '', selectPlaceholder = true) => {
    const element = textarea.current;
    const text = value || '';
    const start = element ? element.selectionStart : text.length;
    const end = element ? element.selectionEnd : text.length;
    const selected = text.slice(start, end) || placeholder;
    const next = `${text.slice(0, start)}${before}${selected}${after}${text.slice(end)}`;
    const from = start + before.length;

    pendingSelection.current = [selectPlaceholder ? from : from + selected.length, from + selected.length];
    onChange(next);
  };

  // Line-level formatting applies at the start of the current line.
  const prefixLine = (prefix, placeholder) => {
    const element = textarea.current;
    const text = value || '';
    const start = element ? element.selectionStart : text.length;
    const lineStart = text.lastIndexOf('\n', start - 1) + 1;

    if (element) {
      element.setSelectionRange(lineStart, element.selectionEnd);
    }

    edit(prefix, '', text.slice(lineStart, element ? element.selectionEnd : text.length) || placeholder);
  };

  const onLink = () => {
    const element = textarea.current;
    const text = value || '';
    const start = element ? element.selectionStart : text.length;
    const end = element ? element.selectionEnd : text.length;
    const selected = text.slice(start, end) || 'link text';
    const next = `${text.slice(0, start)}[${selected}](https://)${text.slice(end)}`;
    const from = start + selected.length + 3;

    // Select the address so the curator can type or paste over it.
    pendingSelection.current = [from, from + 'https://'.length];
    onChange(next);
  };

  const onPickImage = (path, asset) => {
    setPicking(false);
    edit(`![${asset?.filename?.replace(/\.[^.]+$/, '') || 'Image description'}](${path})`, '', '', false);
  };

  return (
    <div className='field'>
      <span className='field-label'>{ label }</span>
      <div className='markdown-field'>
        <div className='markdown-toolbar' role='toolbar' aria-label={`${label} formatting`}>
          <div className='markdown-tabs'>
            <button aria-pressed={!preview} className='markdown-tab' onClick={() => setPreview(false)} type='button'>Write</button>
            <button aria-pressed={preview} className='markdown-tab' onClick={() => setPreview(true)} type='button'>Preview</button>
          </div>
          { !preview && (
            <div className='markdown-buttons'>
              <button onClick={() => edit('**', '**', 'bold text')} onMouseDown={keepFocus} title='Bold' type='button'><strong>B</strong></button>
              <button onClick={() => edit('*', '*', 'italic text')} onMouseDown={keepFocus} title='Italic' type='button'><em>I</em></button>
              <button onClick={() => prefixLine('## ', 'Heading')} onMouseDown={keepFocus} title='Heading' type='button'>H</button>
              <button onClick={() => prefixLine('- ', 'List item')} onMouseDown={keepFocus} title='Bulleted list' type='button'>• List</button>
              <button onClick={onLink} onMouseDown={keepFocus} title='Link' type='button'>Link</button>
              { onUpload && <button onClick={() => setPicking(!picking)} title='Image' type='button'>Image</button> }
            </div>
          )}
        </div>
        { picking && !preview && (
          <AssetPicker
            assets={assets}
            onCancel={() => setPicking(false)}
            onPick={onPickImage}
            onUpload={onUpload}
          />
        )}
        { preview
          ? <div className='markdown-preview' dangerouslySetInnerHTML={{ __html: html || '<p class="muted">Nothing to preview.</p>' }} />
          : (
            <textarea
              aria-label={label}
              className='input markdown-input'
              onChange={(e) => onChange(e.target.value)}
              ref={textarea}
              rows={rows}
              value={value || ''}
            />
          )}
      </div>
      { !preview && !_.isEmpty(images) && (
        <div className='markdown-images'>
          <span className='field-hint'>Images in this text:</span>
          { _.map(images, (image) => (
            <span className='markdown-image' key={image.path}>
              <img alt='' src={image.asset.thumbnail_path || image.path} />
              <Button aria-label={`Crop ${image.alt || image.asset.filename}`} onClick={() => setCropping(image)} subtle>Crop…</Button>
            </span>
          ))}
        </div>
      )}
      { cropping && (
        <ImageCropper
          asset={cropping.target.asset}
          initial={cropping.target.initial}
          label={cropping.alt || `${label}: image`}
          onCancel={() => setCropping(null)}
          onCropped={onCropped}
        />
      )}
      { hint && <span className='field-hint'>{ hint }</span> }
    </div>
  );
};

export default MarkdownField;
