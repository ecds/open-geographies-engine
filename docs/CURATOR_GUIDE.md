# Making an atlas: a guide for curators

An atlas is a public website about places: a map you can search and filter, a page for every
place, and pages of your own (a home page, About, Credits…). You build it in the **Open
Geographies console**, using the places, fields and relationships your FairData project holds.
Nothing here needs code.

This guide follows the order you'd usually work in. Every name in **bold** is what the console
shows.

**Contents**

1. [Before you start](#1-before-you-start)
2. [Sign in](#2-sign-in)
3. [Create an atlas](#3-create-an-atlas)
4. [Add your places](#4-add-your-places)
5. [Places without a location](#5-places-without-a-location)
6. [Categories](#6-categories)
7. [The home page and your pages](#7-the-home-page-and-your-pages)
8. [Branding](#8-branding)
9. [Images](#9-images)
10. [Search and filters](#10-search-and-filters)
11. [Place pages](#11-place-pages)
12. [Map layers and historic maps](#12-map-layers-and-historic-maps)
13. [Languages](#13-languages)
14. [Preview and publish](#14-preview-and-publish) (and [deleting an atlas](#deleting-an-atlas))
15. [Your own domain](#15-your-own-domain)
16. [People: owners and editors](#16-people-owners-and-editors)
17. [Keeping track, and when something goes wrong](#17-keeping-track-and-when-something-goes-wrong)
18. [Quick reference](#18-quick-reference)

---

## 1. Before you start

- **A FairData account.** Someone who runs your FairData site creates it, or an atlas owner invites you
  (see [People](#16-people-owners-and-editors)).
- **Your data**, if you have it: one row per place in a spreadsheet (Excel, OpenDocument or CSV), or a
  GeoJSON file or zipped shapefile. It helps to have:
  - a **name** column;
  - where each place is: **latitude and longitude** in decimal degrees (33.749, -84.388), a street
    **address** (U.S. addresses can be looked up for you), or a shape (GeoJSON, a shapefile, or WKT
    text in a column);
  - a **category** column (building, district, church…) that becomes the atlas's main filter;
  - a column with a **unique id** for each row from your source (a record number or link), so you
    can import the same file again later without duplicates;
  - optionally a column of **photo links**.
- **Images** for the look of the atlas: a logo, a banner photo. Large photos are fine; the atlas makes
  copies sized for every screen.

You can also start without data, from a gazetteer (GeoNames or Wikidata), and add places in
FairData by hand.

## 2. Sign in

Open the console at your FairData site's address followed by `/atlases` (the **Guide ↗** link at
the top of the console brings you back here). **Sign in with your FairData account**. The header
has **Atlases** (the list of atlases you work on) and **Create an atlas**.

## 3. Create an atlas

**Create an atlas** walks through four steps:

1. **Basics**
   - **Atlas name** (required). It also makes the atlas's address, so two atlases can't share a name.
   - A **Description**: the home page starts with it.
   - The **Default language**.
   - A **Starter template**: **Places** (places and a place-type vocabulary, the lightest start) or
     **Atlas** (places, media, works, people and organizations, with **Optional modules**).
   - Optionally a **Geographic area**, chosen by **Administrative units** (country, state, counties) or
     drawn with **Draw on map**. It's only needed to find places in a gazetteer, so skip it if you're
     bringing your own data.
2. **Provision**: the console sets the atlas up. When it's done, choose **Continue**.
3. **Add places**: upload your data or import from a gazetteer, as in the next section, or
   **Skip for now**.
4. **Done**: the atlas is ready to build. It's a **draft**: private, with a preview link, until
   you publish it. Choose **Open atlas settings**.

Each atlas then has tabs: **Settings**, **Places**, **Imports**, **Jobs**, and for owners
**People →**.

## 4. Add your places

Under **Imports** (or step 3 of the wizard), choose **Upload your data**.

### Upload and preview

Choose your file and **Preview**. Nothing is imported until you review it and press **Import**.

- **Files read:** Excel `.xlsx`, OpenDocument `.ods`, CSV or tab-separated text (`.csv`, `.tsv`,
  `.txt`), GeoJSON (`.geojson` or `.json`), and a shapefile zipped with its `.dbf`, `.shx` and `.prj`.
  Up to 50 MB and 50,000 rows.
- **Converting other files:**
  - **Older `.xls`:** save it as `.xlsx` or CSV in Excel first.
  - **KML:** convert it to GeoJSON (with QGIS or geojson.io).
  - **Shapefiles:** they must be in latitude/longitude (WGS 84). The console explains how to
    convert a projected one in QGIS.

The preview counts your **Rows**, how many have a location of each kind, and how many have **No
location** or an **Unusable location**, and shows the located rows on a map.

### Tell it what each column is

The **Columns** table lists every column with examples. Under **Use as**, choose:

| Use as | For |
|---|---|
| **Place name** | The place's name (one column). |
| **Latitude** / **Longitude** | Coordinates in decimal degrees (both or neither). |
| **Geometry** | A column of shapes as WKT or GeoJSON (instead of latitude/longitude). |
| **Category** | The atlas's place-type filter. Separate several values with `;`. |
| **Identifier** | A unique id from your source. Importing the file again skips rows already in the atlas. |
| **Photo (image address)** | Links to images, shown as each place's picture. |
| **Field** | Anything else to show on the place's page. Give it a **Field name** and a **Type**. |
| **Don't import** | Leave it out. Columns that look like file bookkeeping start this way. |

**Field types:**
- **Short text** and **Long text**.
- **Pick-list (filterable)**: these become filters on the atlas.
- **Number**.
- **Yes / No**: marked rows are Yes, blank rows are No.
- **Date (a year, month or day)**: partial dates such as `1983` or `1983-03` are fine.
- **Exact date (YYYY-MM-DD)**.

If some values don't fit the type you chose, the console says how many would be left empty and
suggests another type.

**Shortcuts:**
- The console remembers your choices: a second file with the same columns can **Use last upload's
  choices**.
- **Skip all fields** and **Restore suggestions** reset the table quickly.
- For a category column written in lower case, **Capitalize** offers proper capitals (terms that
  already have capitals stay as written).

### Places with only an address

If rows have no coordinates but have a U.S. street address, **Find locations from addresses**
looks them up:

1. Choose the **Street address** column, and the **City**, **State** and **ZIP code** columns. You can
   type one value for every row instead, for example the state.
2. **Find locations**. The console shows what was **Found** exactly, what was found only **near the
   address**, and what was **Not placed**.
3. Matches near an address are left out unless you include them. Check those: an old street name can
   match a similar street.

Places that aren't found are still imported: they're listed and searchable, just not on the map.
You can place them afterwards (section 5).

### Photos

If you have a **Photo** column and your atlas has an image server, the box **Copy the photos to the
atlas's image server** is ticked. The photos are then stored with sizes for every screen and shown on
search results. Untick it if you don't have the right to copy them; they're then shown from their
source.

### Import

Choose **Import**. The results show what was **Imported**, what was **Already in the atlas**, and
anything that **Failed**, with **Rows to check**. The atlas then updates (**Updating the
atlas…**); your places are live when it says **The atlas is updated**.

An import also sets up the atlas for you:
- the category and pick-list fields become **filters**;
- text fields such as addresses are added to what the search box looks in;
- the identifier column is hidden from public pages. You can change any of this later.

### From a gazetteer

**From a gazetteer** imports places from **GeoNames** (by area, with **Feature classes** such as
"P — Cities, towns, villages", and optional feature codes or a name filter) or **Wikidata** (by an
area you draw, with **Place types** such as buildings or museums). **Preview** shows how many match
and a sample on the map; **Import** brings them in.

Imports are safe to run again: places already imported are skipped.

## 5. Places without a location

**Places → Without a location** lists the places that aren't on the map yet. There are two ways
to place them:

- **Look up their addresses all at once**: choose the field holding the street address (and city,
  state, ZIP), then **Look up**. Review what was found; exact matches are ticked, matches near the
  address aren't. Then **Save** the locations.
- **Place them on the map** one at a time: pick a place, search for it, or click the map where it
  is and drag the marker to adjust. Then **Save location**, or **Skip for now**.

Placed places appear on the atlas's map within a minute or so.

## 6. Categories

**Places → Categories** lists each category's values and how many places use each. To fix a
spelling or wording, edit a value and press **Rename**. Renaming it to the name of another value
**merges** the two. The atlas's filter, search results and place pages follow within a minute or
so.

## 7. The home page and your pages

**Settings → Home page** is the atlas's front page, built from **sections** you add top to bottom:

- **Banner**: a large title over your brand color or a photo, with an optional search box and button.
  Leave the title blank to show the atlas's title.
- **Text**: a heading and formatted text.
- **Text and image**: text beside an image, left or right.
- **Call to action**: a short prompt with a button, for example into the map.

Move sections with ↑ ↓, and **Remove** them.

**Writing text.** Text boxes have **Write** and **Preview** tabs and buttons for **B** (bold),
**I** (italic), **H** (heading), **• List**, **Link** and **Image**.

**Links** can go to:
- a page of the atlas: `/en/search/places` for the map, `/en/pages/about` for a page;
- a full address: `https://…`.

**Images** come from your uploads or an `https://` address. Describe each image for screen
readers, or leave the description empty if the image is decorative.

**Settings → Pages & menu**:
- **+ Add page** for pages such as About, Credits or How to cite.
- Each page has a **Title**, an **Address** (`/en/pages/<address>`), a **Description** and sections.
- **Menu:** by default it shows Explore (the map) and then every page in order. **Customize the menu**
  lets you choose items, rename them and add links.

Press **Save** at the bottom of Settings; the atlas shows your changes within 30 seconds.

## 8. Branding

**Settings → Branding** sets the look of the whole atlas:

- **Site title** and **Site description** (used by search engines and link previews).
- **Logo** (a transparent PNG or SVG works best), **Favicon** (the browser tab icon), and **Share
  image** (for link previews, about 1200×630).
- **Header font** and **Body font**.
- The **Colors**: primary, secondary, background, text and so on.
- **Footer**:
  - a **Credit line**;
  - links to **Terms**, **Privacy** and **Accessibility** pages;
  - a **Copyright or rights line** (`{year}` becomes the current year; leave it empty for none);
  - **Partner logos**, each with a name read out by screen readers.

## 9. Images

**Settings → Images** lists every image uploaded for the atlas and where each is used: the logo,
favicon, link preview image, footer, home page, a particular page, or other settings. That includes
changes you haven't saved yet.

- **Upload images…** adds several at once. Accepted: PNG, JPEG, GIF, WebP, AVIF, SVG or ICO up to
  10 MB; TIFF up to 100 MB, stored as a JPEG.
- Images marked **Not used** can be deleted one at a time (**Delete…**) or all together (**Delete the
  unused ones…**).
- Deleting an image that's still in use tells you which places will show no image. Deleting can't be
  undone.

## 10. Search and filters

**Settings → Search** sets up the atlas's map search:

- **Facets** are the filters beside the results, in order. Only fields the search can filter on are
  offered: categories, pick-lists, relationships.
- **Filter names**: what visitors see above each filter (for example "Building types" instead of
  "Types").
- **Also search in**: the search box always looks at names and descriptions; add other text fields
  such as an address.
- **Result card attributes**: what each search result shows under the name.
- **Shows results as**: a map with the results beside it (the usual), or without a map: a list,
  a grid of cards, or an image gallery.

## 11. Place pages

Every place has its own page, and a panel on the map. **Settings → Detail pages** controls what
they show:

- **Hidden fields:** pick fields that are internal bookkeeping (legacy ids, old links, slugs) to hide
  them from the public. Each record type has its own list.
- **Section names:** related records are grouped under headings taken from FairData, such as
  "Contained In" or "Types". Type the name you want on the atlas ("County", "Kind of building") next
  to each, or leave it empty to keep FairData's. With more than one language, there's a box per
  language.

## 12. Map layers and historic maps

### Historic maps

You can lay a scanned historical map over the atlas's map, aligned to today's streets. The scan has
to be *georeferenced* in [Allmaps](https://allmaps.org): a free tool where you match a few points on
the scan to the same places on today's map. Under **Settings → Map layers → Add a historic map**:

1. Paste the map's Allmaps link, or the IIIF address of the scan (libraries and archives usually label
   it "IIIF manifest"), and choose **Find**.
2. If it's already georeferenced, you'll see a thumbnail, its title and its outline on a small map.
   - Name it as visitors will see it in the map's layer menu.
   - Set its **Opacity**.
   - Choose whether it's **Shown when the map opens**.
   - Choose **Add to the atlas**, then **Save**.
3. If it isn't georeferenced yet, or Allmaps can't look the address up, choose **Open in the Allmaps
   Editor**. Place your points there, then paste the Allmaps link it gives you.

Visitors switch historic maps on and off with the layers button on the map.

### Other layers

The **Layers** list below holds the base maps visitors choose from and any other overlays: map
tiles, a PMTiles archive, GeoJSON. Each has a name, a type, its address, and whether it's an
**Overlay** and **Visible by default**.

## 13. Languages

An atlas can be in English, Spanish, French, German, Italian and Portuguese. Under **Settings →
General → Languages**, choose the **Default language** and tick the others under **Also in**.
Visitors switch languages from the menu at the top of the atlas.

Then translate, using the **Language** switch at the top of the **Home page** and **Pages & menu**
tabs:

- **Home page:** choose **Start from the English version** (or your default language's) and translate
  the copy.
- **Pages:** each page shows **Translated** or **Shows in English**. Choose **Translate (start from the
  English version)**, then edit its title, description and sections. Add, remove and reorder pages in
  the default language only.
- **Menu:** if you've customized the menu, give each item a label in the other language. If you
  haven't, the menu follows the pages: each page shows under its translated title, and "Explore" is
  translated for you.

Anything you don't translate shows in the default language. Links between the atlas's own pages
keep visitors in the language they're reading. The atlas's own buttons and labels (Search,
Filters…) are in English for now.

## 14. Preview and publish

A new atlas is a **draft**: only people with its preview link can see it. Under **Settings →
General → Visibility**:

- **Copy** or **Open ↗** the preview link to show the atlas to colleagues. Anyone who has the link
  can see the draft, so share it with care.
- **Replace preview link…** makes a new link and stops the old one working.
- **Publish atlas** makes it public at its address straight away.
- **Unpublish…** takes it back to a draft; visitors then find no atlas at the address.

The atlas header says **Draft** or **Published**, and **Preview ↗** or **View atlas ↗** opens it.

### Deleting an atlas

Owners can delete an atlas at the bottom of **Settings → General** (**Delete this atlas…**, then
type its name to confirm). This deletes its website, pages, branding, images, settings and
address. Its places and other records stay in its FairData project. It can't be undone.

## 15. Your own domain

Every atlas has a platform address built from its name. It can also have a domain of its own,
such as `atlas.example.org`. Under **Settings → General → Address**:

1. Type the domain and choose **Add domain**. It shows **Waiting for DNS**.
2. Ask whoever manages that domain's DNS to add the record the console shows:
   - for a subdomain (`atlas.example.org`), a **CNAME** to the atlas's platform address;
   - for a root domain (`example.org`), a **TXT** record, plus A or ALIAS records your platform's
     administrators can give you.
3. Choose **Check DNS**. DNS changes can take a few hours to reach everywhere.

Once it shows **Connected**, the atlas is served at your domain, and its platform address sends
visitors there.

- **The `www.` version:** optionally point it the same way; visitors who type it are sent to your
  domain.
- **Keep the DNS record in place:** the atlas is served at your domain only while the record points to
  the platform.
- **Remove domain…** puts the atlas back on its platform address.

## 16. People: owners and editors

The people who work on an atlas are the members of its FairData project. **People →** in the atlas
header (for owners) opens the project's **Users** page in the FairData console. There, owners
invite people by email and choose their role:

- **Editors** do the content work:
  - settings, pages, branding and images;
  - map layers, searches and place pages;
  - placing places, categories, imports and reindexing.
- **Owners** do all of that, and also:
  - publish and unpublish the atlas;
  - change its address and domain;
  - replace the preview link;
  - delete it ([Deleting an atlas](#deleting-an-atlas)).

Someone invited by email can work on the atlases they've been added to, but can't create new ones.

## 17. Keeping track, and when something goes wrong

- **Jobs** lists the atlas's imports, reindexes and other background work, with their status
  (**Queued**, **Running**, **Completed**, **Failed**) and details.
- **Reindex** (Settings → General → Search index) rebuilds what the atlas searches from your data.
  Use it after editing many places directly in FairData.
- If **The atlas couldn't be updated** after an import, your places are saved; the message says
  why:
  - Another atlas already uses one of your field names for a different kind of value. Rename your
    field in FairData, then reindex.
  - The search index is full. An administrator needs to make room.
- **How quickly changes show:**
  - Settings and pages: within 30 seconds.
  - Placed places and category renames: within a minute or so.
  - Copied photos: about one a second.

## 18. Quick reference

| | |
|---|---|
| Data files | .xlsx, .ods, .csv, GeoJSON, zipped shapefile (WGS 84); up to 50 MB and 50,000 rows |
| Address lookup | U.S. street addresses |
| Images | PNG, JPEG, GIF, WebP, AVIF, SVG, ICO up to 10 MB; TIFF up to 100 MB |
| Languages | English, Spanish, French, German, Italian, Portuguese |
| Historic maps | Georeferenced in Allmaps (allmaps.org), from a IIIF scan |
| Draft → public | Settings → General → Visibility → **Publish atlas** (owners) |
| Changes live | Within 30 seconds of **Save** |
