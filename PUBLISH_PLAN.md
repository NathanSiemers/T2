# Publication-quality figures from T2 — plan

Status: proposal, nothing built. Written 2026-10-04 in answer to the last item of
`../Thanos/thanos.notes.md`. Numbers below were measured in the dev container on the
TCGA CD8A × FOXP3 scatter (11,005 points).

## What the user should be able to do

"I want a 3.5 × 2.8 inch figure at 300 dpi, as a TIFF." They set that on a **Publish** tab,
watch a live preview that is the real figure, adjust it until it reads well at that size,
and download the file.

## The two questions in the note, answered

**Can we give an accurate view of the real thing?** Yes, and without controlling the browser
at all. The server draws the figure with the same device, at the same physical size, that the
download will use; the browser only displays that picture. I checked the one thing this
depends on: a figure drawn at 100 dpi and at 300 dpi has the *same layout* (same line breaks,
same legend, same panel size), because every size in ggplot is physical (points, mm) and the
resolution only decides how many pixels describe it. So the preview is not an emulation.

What a browser cannot promise is *true physical size on the screen*, because it does not know
the monitor's real pixel density. The preview therefore offers "fit to window" and "pixel for
pixel" (for checking sharpness), and states the size in words next to it.

**Are the on-screen Appearance settings usable for the figure?** No — you were right. I drew
the current default plot at 3.5 × 2.8 in to see: the legend takes two thirds of the figure,
the caption is larger than the title, and the fit line is a slab. The Plot tab is about
19 inches wide in ggplot's terms, so its sizes are for a canvas five times larger. Shrinking
everything by one factor does not rescue it either: 11 pt text would become 2 pt. A printed
figure needs its own sizes (journals ask for 5–8 pt text *at final size*), and that changes
the layout, not just the scale.

## Design

### 1. A separate figure profile
The Publish tab has its own copy of the Appearance controls (the fixed settings plus the
searchable ggplot settings), with its own values. It never changes what the Plot tab shows.

- **Start from a preset** that sets size, resolution *and* a matching style: text 6–8 pt,
  small points, thin lines, compact legend keys and spacing, small margins.
  Proposed presets: single column (89 mm), 1.5 column (120 mm), double column (183 mm),
  slide 16:9 (13.33 × 7.5 in), poster panel, and "custom".
- **Or start from my Appearance settings** (copies them, for people who want that).
- **One "overall scale" knob** as well as the individual sizes: it scales text, lines and
  points together (the drawing device supports this directly), for quick coarse adjustment.

To avoid two copies of the controls drifting apart, the Appearance controls become one
reusable component used twice (screen profile, figure profile). The registry and the
validation in `plot_style.R` are reused unchanged.

### 2. Size, resolution, format
- Width and height in inches, cm or mm; resolution from a menu (150, 200, 300, 600, 1200 dpi).
- A readout: "3.5 × 2.8 in at 300 dpi = 1050 × 840 pixels, about 150 KB".
- Formats: PNG and TIFF (LZW-compressed) as requested. I recommend adding **PDF** too: it is
  vector, so resolution stops mattering, and it is what many journals prefer for plots. It
  costs almost nothing to add.
- Server-side limits, validated like every other input: each side ≤ 20 in, ≤ 1200 dpi,
  ≤ about 60 megapixels. These keep one request from exhausting the server's memory.

### 3. Live preview
- Redraws about one second after the last change.
- Draws from the data of the last **Plot** press (same variables, cohort, Filter-tab
  survivors), kept in memory, so a redraw is drawing only.
- Measured: drawing takes 1.0–1.7 s and barely depends on resolution (a 7 × 5 in figure at
  600 dpi took 1.7 s). So the preview can usually be the final image itself; above about
  200 dpi it is drawn at 200 dpi to keep the transfer small, which by the layout check above
  shows the same figure.
- "Download figure" then renders at full resolution and sends the file.

### 4. Attribution
- A "Show source line" checkbox on the Publish tab, on by default (today's caption).
- When it is unticked, a notice appears next to the download button, with the citation and
  URL ready to copy: the figure may be used without the line, but T2 must be cited.
- The downloaded file name carries the origin, e.g. `T2_CD8A_vs_FOXP3_3.5x2.8in_300dpi.tiff`.

### 5. Survival plots
Kaplan-Meier figures (curve plus risk table) go through the same path; the risk table needs
its own text size setting in the figure profile.

## Work required

1. **Split drawing from data fetching** in `plotter()` / `survival_km()`, so a plot can be
   redrawn with new styling without querying the database (1.4 s of today's 2.8 s).
2. **Appearance controls as a reusable component**, instantiated for screen and figure.
3. **`figure_export.R`**: presets, size/resolution validation, one `render_figure()` used by
   both preview and download (ragg devices; ragg is already installed in the dev and the live
   container).
4. **Publish tab**: controls, readout, preview with the two zoom modes, download.
5. **Attribution** switch, notice and file naming.
6. **Tests**: output files have exactly the requested pixel size and resolution; preview and
   download show the same layout (compare a downsampled download with the preview); limits
   are enforced; browser test of the live preview and the download.

Roughly the size of the Appearance work just done; steps 1 and 2 are the bulk and also make
the existing code cleaner.

## Risks and limits

- **One slow render blocks other users.** Shiny serves all sessions of an app from one R
  process, so a 2-second render is 2 seconds of waiting for everyone. The size limits bound
  it; making renders asynchronous is possible later but needs a newer Shiny than the live
  container has (1.7.5).
- **Fonts.** Journals often ask for Arial or Helvetica. The containers have neither; they
  have metric-compatible Helvetica clones (Nimbus Sans, TeX Gyre Heros). Either those are
  offered under their real names, or Arial-compatible fonts are added to the image.
- **Colour model.** Output is RGB. A journal that insists on CMYK TIFF needs a conversion
  step outside T2.
- **Very dense scatters as PDF** are large files (one object per point); PNG/TIFF are not
  affected.

## Decisions needed from you

1. The **citation text and URL** for the notice (and whether the default source line should
   say more than your name, e.g. the site address).
2. **PDF as a third format** — yes or no. (Recommended: yes.)
3. Which **presets** matter to you; the list above is a guess.
4. **Fonts**: accept the Helvetica clones, or add Arial-compatible fonts to the images?
5. Are the **limits** (20 in, 1200 dpi, about 60 megapixels) acceptable?
6. Should the **Plot tab** also get a plain "download this plot as shown" button, separate
   from the Publish tab?
