import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState
} from 'react';
import _ from 'underscore';
import { errorMessages } from '../api';
import { Button, Message } from './ui';

/**
 * How the atlas editor crops an uploaded image: `(key, rect) => Promise<asset>`
 * (POST /core_data/sites/:id/assets/:key/crop, the new image added to the
 * library). ImageField offers Crop… only where it's provided.
 */
export const ImageCropContext = createContext(null);

/**
 * The shapes the atlas shows images at, where it has one. A banner fills the
 * width of the screen at a fixed height (about 3:1 on a desktop; phones show
 * its middle); link previews (og:image) are 1.91:1 at 1200 × 630; a favicon
 * is square. Logos and section images keep any shape.
 */
export const CROP_SHAPES = {
  banner: {
    aspect: 3,
    aspectLabel: '3:1, the banner’s shape on a wide screen (phones show its middle)',
    mismatch: 'a banner shows about 3:1 on a wide screen',
    minWidth: 1600
  },
  linkPreview: {
    aspect: 1.91,
    aspectLabel: '1.91:1, the shape link previews use',
    mismatch: 'link previews are 1.91:1',
    minWidth: 1200,
    minHeight: 630
  },
  favicon: {
    aspect: 1,
    aspectLabel: 'square, as browser tabs show it',
    mismatch: 'a favicon is square',
    minWidth: 64,
    minHeight: 64
  }
};

/** Types the server can crop (SiteImages::RESIZABLE_TYPES). */
export const CROPPABLE_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/avif'];

const MIN = 16;
const clamp = (value, low, high) => Math.min(Math.max(value, low), high);

/**
 * The largest rectangle of `aspect` (width / height) centred in a W × H image;
 * the whole image when there's no aspect.
 */
export const largestCentered = (W, H, aspect) => {
  if (!aspect) return { x: 0, y: 0, w: W, h: H };

  const w = Math.min(W, H * aspect);
  const h = w / aspect;
  return { x: (W - w) / 2, y: (H - h) / 2, w, h };
};

/**
 * Where a re-crop starts: the earlier frame when it already has `aspect` (or
 * the field takes any shape); else the largest rectangle of `aspect` inside
 * it, centred — an earlier square crop opened for a 3:1 banner keeps its
 * middle, at the banner's shape. The whole image when that would be tiny.
 */
export const startingRect = (initial, W, H, aspect) => {
  if (!initial) return largestCentered(W, H, aspect);

  const r = { x: initial.x, y: initial.y, w: initial.width, h: initial.height };
  if (!aspect || Math.abs(r.w / r.h - aspect) / aspect <= 0.01) return r;

  const w = Math.min(r.w, r.h * aspect);
  const h = w / aspect;
  if (w < MIN || h < MIN) return largestCentered(W, H, aspect);

  return { x: r.x + (r.w - w) / 2, y: r.y + (r.h - h) / 2, w, h };
};

/**
 * A rectangle after dragging `mode` (move, or an edge/corner: n, s, e, w, ne,
 * nw, se, sw) by dx, dy image pixels, kept inside the image, at least MIN
 * pixels, and at `aspect` when there is one (the edge or corner opposite the
 * one dragged stays put; dragging a side keeps the rectangle centred across).
 */
export const dragRect = (r, mode, dx, dy, aspect, W, H) => {
  if (mode === 'move') {
    return { ...r, x: clamp(r.x + dx, 0, W - r.w), y: clamp(r.y + dy, 0, H - r.h) };
  }

  let left = r.x;
  let top = r.y;
  let right = r.x + r.w;
  let bottom = r.y + r.h;

  if (mode.includes('w')) left = clamp(left + dx, 0, right - MIN);
  if (mode.includes('e')) right = clamp(right + dx, left + MIN, W);
  if (mode.includes('n')) top = clamp(top + dy, 0, bottom - MIN);
  if (mode.includes('s')) bottom = clamp(bottom + dy, top + MIN, H);

  if (!aspect) return { x: left, y: top, w: right - left, h: bottom - top };

  const horizontal = /[ew]/.test(mode);
  const vertical = /[ns]/.test(mode);
  let w = right - left;
  let h = bottom - top;

  if (horizontal && (!vertical || Math.abs(dx) >= Math.abs(dy) * aspect)) {
    h = w / aspect;
  } else {
    w = h * aspect;
  }

  // The fixed point: the opposite edge, or the centre across a dragged side.
  const anchorX = mode.includes('w') ? r.x + r.w : (mode.includes('e') ? r.x : r.x + r.w / 2);
  const anchorY = mode.includes('n') ? r.y + r.h : (mode.includes('s') ? r.y : r.y + r.h / 2);
  const maxW = mode.includes('w') ? anchorX : (mode.includes('e') ? W - anchorX : 2 * Math.min(anchorX, W - anchorX));
  const maxH = mode.includes('n') ? anchorY : (mode.includes('s') ? H - anchorY : 2 * Math.min(anchorY, H - anchorY));
  const fit = Math.min(1, maxW / w, maxH / h);
  w *= fit;
  h *= fit;

  if (w < MIN || h < MIN) {
    const grow = Math.max(MIN / w, MIN / h);
    w = Math.min(w * grow, W);
    h = Math.min(h * grow, H);
  }

  const x = mode.includes('w') ? anchorX - w : (mode.includes('e') ? anchorX : anchorX - w / 2);
  const y = mode.includes('n') ? anchorY - h : (mode.includes('s') ? anchorY : anchorY - h / 2);

  return { x: clamp(x, 0, W - w), y: clamp(y, 0, H - h), w, h };
};

/** Whole pixels, inside the image: what's sent to the server. */
const toPixels = (r, W, H) => {
  const x = clamp(Math.round(r.x), 0, W - MIN);
  const y = clamp(Math.round(r.y), 0, H - MIN);

  return {
    x,
    y,
    width: clamp(Math.round(r.w), MIN, W - x),
    height: clamp(Math.round(r.h), MIN, H - y)
  };
};

const HANDLES = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'];

/**
 * Crop an uploaded image: drag the rectangle (or its edges and corners), or
 * use the keyboard — arrow keys move it, Shift + arrow keys resize it, add
 * Option/Alt for single pixels. Saves a cropped copy as a new image of the
 * atlas; the original stays in the library.
 *
 * `crop`: { aspect, aspectLabel, minWidth, minHeight } — a fixed shape where
 * the atlas shows the image at one (link previews, the favicon, banners);
 * free otherwise. `initial`: the rectangle to start from (re-cropping an
 * earlier crop opens its original at the earlier rectangle).
 */
const ImageCropper = ({ asset, crop = {}, initial, label, onCancel, onCropped }) => {
  const dialog = useRef();
  const image = useRef();
  const drag = useRef(null);
  // The Crop… button, to give focus back to when the dialog goes.
  const opener = useRef(document.activeElement);
  const cropAsset = useContext(ImageCropContext);
  const W = asset.width;
  const H = asset.height;
  const { aspect } = crop;

  const [rect, setRect] = useState(() => startingRect(initial, W, H, aspect));
  const [scale, setScale] = useState(0);
  const [saving, setSaving] = useState(false);
  const [errors, setErrors] = useState([]);

  useEffect(() => {
    const element = dialog.current;
    const returnTo = opener.current;
    element?.showModal();

    return () => {
      if (element?.open) element.close();
      if (returnTo instanceof HTMLElement && returnTo.isConnected) returnTo.focus();
    };
  }, []);

  // Image pixels per screen pixel: measured when the image loads, and kept
  // current as the dialog resizes.
  const measure = () => {
    const width = image.current?.clientWidth;
    if (width) setScale(width / W);
  };

  useEffect(() => {
    const img = image.current;
    if (!img) return undefined;

    const observer = new ResizeObserver(() => measure());
    observer.observe(img);
    measure();

    return () => observer.disconnect();
  }, [W]);

  const onPointerDown = (e, mode) => {
    e.preventDefault();
    e.stopPropagation();
    // Keeps the drag going when the pointer leaves the frame; a pointer the
    // browser doesn't track (a synthetic event) just goes without.
    try { e.currentTarget.setPointerCapture(e.pointerId); } catch (error) { /* untracked pointer */ }
    drag.current = { mode, startX: e.clientX, startY: e.clientY, rect };
  };

  const onPointerMove = (e) => {
    const current = drag.current;
    if (!current || !scale) return;

    setRect(dragRect(current.rect, current.mode, (e.clientX - current.startX) / scale, (e.clientY - current.startY) / scale, aspect, W, H));
  };

  const onPointerUp = () => { drag.current = null; };

  const onKeyDown = (e) => {
    const steps = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
    const step = steps[e.key];
    if (!step) return;

    e.preventDefault();
    const size = e.altKey ? 1 : Math.max(1, Math.round(Math.max(W, H) / 100));
    setRect((r) => dragRect(r, e.shiftKey ? 'se' : 'move', step[0] * size, step[1] * size, aspect, W, H));
  };

  const pixels = toPixels(rect, W, H);
  const small = (crop.minWidth && pixels.width < crop.minWidth) || (crop.minHeight && pixels.height < crop.minHeight);

  const onSave = () => {
    setSaving(true);
    setErrors([]);

    cropAsset(asset.key, pixels)
      .then(onCropped)
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => setSaving(false));
  };

  const box = scale ? {
    left: rect.x * scale,
    top: rect.y * scale,
    width: rect.w * scale,
    height: rect.h * scale
  } : null;

  return (
    <dialog
      aria-labelledby='crop-title'
      className='feedback-dialog crop-dialog'
      onCancel={(e) => { e.preventDefault(); onCancel(); }}
      ref={dialog}
    >
      <div className='feedback-body'>
        <h2 id='crop-title'>Crop: { label }</h2>
        <p className='muted crop-shape'>
          { aspect ? `Shape: ${crop.aspectLabel}.` : 'Any shape.' }
          { ' ' }
          Drag the frame or its edges; with the keyboard, arrow keys move it and Shift + arrow keys resize it.
        </p>
        <div
          className='crop-stage'
          onPointerCancel={onPointerUp}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
        >
          <img alt='' draggable={false} onLoad={measure} ref={image} src={asset.preview_path || asset.path} />
          { box && (
            <div
              aria-describedby='crop-size'
              aria-label={`Crop frame, ${pixels.width} × ${pixels.height} pixels from the left ${pixels.x}, top ${pixels.y}`}
              className='crop-box'
              onKeyDown={onKeyDown}
              onPointerDown={(e) => onPointerDown(e, 'move')}
              role='group'
              style={box}
              tabIndex={0}
            >
              { _.map(HANDLES, (handle) => (
                <span
                  aria-hidden='true'
                  className={`crop-handle crop-handle-${handle}`}
                  key={handle}
                  onPointerDown={(e) => onPointerDown(e, handle)}
                />
              ))}
            </div>
          )}
        </div>
        <p className='crop-size' id='crop-size' aria-live='polite'>
          { pixels.width } × { pixels.height } pixels
          { small && (
            <span className='crop-warning'>
              { ' — ' }
              smaller than { crop.minWidth }{ crop.minHeight ? ` × ${crop.minHeight}` : ' pixels wide' }; it may look soft where it’s shown large.
            </span>
          )}
        </p>
        { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
        <p className='muted feedback-sent-along'>Saves a cropped copy as a new image; the original stays in your images.</p>
        <div className='actions'>
          <Button onClick={() => setRect(largestCentered(W, H, aspect))} subtle>{ aspect ? 'Largest that fits' : 'Whole image' }</Button>
          <span className='spacer' />
          <Button onClick={onCancel} subtle>Cancel</Button>
          <Button loading={saving} onClick={onSave} primary>Save cropped copy</Button>
        </div>
      </div>
    </dialog>
  );
};

export default ImageCropper;
