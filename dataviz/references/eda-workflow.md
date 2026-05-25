# EDA Workflow for Rigorous Dataset Analysis

Source material for `~/.claude/skills/dataviz/references/eda-workflow.md`. Synthesized from Tukey (1977), Cleveland-McGill (1984), Tufte, Hadley Wickham (grammar of graphics), Munzner, Knaflic.

## Phase 1: Profile (Data Quality Pass)

**Structural inventory**
- Row count, column count, memory footprint, file encoding (UTF-8 vs Latin-1 — sniff BOM)
- Declared dtype vs inferred dtype: flag numeric-as-string (`"1,234.56"`, `"$42"`), dates-as-string, booleans-as-0/1
- Primary key candidates: any column with `nunique == nrows`?

**Dtype inference heuristics (concrete rules)**
- Leading-zero numerics → treat as string (postal codes, SKUs, order IDs)
- Column name matches regex `(?i)(id|code|zip|postal|phone|sku|barcode|uuid|hash)` → force string
- Cardinality > 0.95 × nrows AND looks numeric → likely identifier, exclude from stats
- If parseable as number AND name does not match ID pattern AND cardinality < 0.95 → numeric
- Else → string/categorical

**Missingness**
- Column-wise null rate + row-wise null rate (histogram of nulls-per-row)
- Classify pattern: **MCAR** (random, drop safely), **MAR** (depends on observed — impute conditionally), **MNAR** (depends on unobserved — flag, never silently impute)
- Visualize with a missingness matrix to spot block patterns
- Column with >40% nulls: flag for drop unless semantically critical
- Column with 100% nulls: drop unconditionally, list in profile
- Column with 1 unique value: keep as "constant context", surface once in BLUF, exclude from charts

**Duplicates & near-duplicates**
- Exact row duplicates
- Near-duplicates on key fields (strip whitespace, lowercase, fuzzy match for text)

**Constant / low-variance columns**
- `nunique == 1` → constant context (keep metadata, drop from charts)
- `nunique / nrows < 0.01` on non-categorical → flag
- Categorical with one dominant class >95% → flag

**Hygiene**
- Trim whitespace, normalize case on categoricals (detect `"USA"`, `"usa"`, `" USA"` collisions)
- Date parsing: infer format, flag mixed formats; attempt auto-parse column-wide, fall back to string if mixed
- Numeric ranges: negative where impossible (age = -5), future dates where impossible

**Outliers**
- Per numeric column: IQR rule (1.5×IQR) + z-score (|z|>3) — report count, not auto-remove
- Multivariate: Mahalanobis distance for multivariate normal-ish data; Isolation Forest for high-dim / non-parametric
- Tag outliers, don't delete — they're often the signal

**Guards (skill must bail gracefully)**
- n = 0: stop with "dataset is empty, nothing to analyze"
- n = 1: univariate only, no SD/Pearson (both undefined)
- cols = 1: univariate only, skip bivariate
- >50k rows: auto-aggregate (pre-bin histograms, sample scatters, group time series)
- >500k rows: refuse interactive mode; offer summary-only report

## Phase 2: Univariate

**Numeric**
- Five-number summary + mean, SD, skewness, kurtosis
- Histogram with **Freedman-Diaconis** bins (`2·IQR/n^(1/3)`) for robust default; fall back to Sturges for small n
- ECDF (more honest than histogram — no binning artifact)
- Boxplot + Q-Q plot against normal
- Skew > 1 or < -1: suspect log-normal; heavy tail + monotone decay: suspect power-law (check log-log plot)
- Always report: is this approximately symmetric, right-skewed, bimodal, or heavy-tailed?

**Categorical**
- Frequency table + mode
- Cardinality bucket: low (<10), medium (10-50), high (>50, often ID-like)
- Rare categories (<1% frequency): bucket into "Other" for viz, preserve for analysis
- Very high cardinality (>50): top-N + "Other" bucket for charts (default N=10)

**Temporal**
- Min/max/span, sampling rate (median gap), missing intervals
- Quick ACF plot for seasonality hints (daily/weekly/yearly cycles)

## Phase 3: Bivariate / Multivariate

**Numeric × numeric**
- Pearson for linear, Spearman for monotonic — compute both, divergence signals non-linearity
- Correlation matrix heatmap; flag |ρ|>0.9 as collinearity risk
- Scatter matrix for top correlations; annotate R² on each

**Categorical × numeric**
- Grouped boxplots + strip overlay; report effect size (Cohen's d, or η² for ANOVA) not just p-value
- Small group sizes (<30): use violin or raw points, avoid summary stats

**Categorical × categorical**
- Contingency table, row/column percentages, Cramér's V (0-1 effect size; chi-square alone is sample-size-inflated)
- Mosaic plot for 2-way, heatmap for higher-dim

**Temporal × numeric**
- Trend (rolling mean), autocorrelation, changepoint detection (flag structural breaks)

**Simpson's paradox check (concrete heuristic)**
- For every headline bivariate relationship, try every categorical column with cardinality 2–10 as a conditioner
- Recompute relationship within each group
- Flag any direction-flip between aggregate and within-group pattern
- When detected: lead the report with the paradox, not the aggregate

## Phase 4: Signal Extraction

Produce an insight list ranked by **effect size × reliability × surprise**:
1. **Headline**: the single finding a journalist would lead with
2. **Surprises**: asymmetric distributions, unexpected correlations, top/bottom decile outliers
3. **Segmentation**: which subgroups behave differently (interaction effects)
4. **Relationships**: what predicts what (with effect size, not just significance)
5. **Caveats**: null rates, sample size per segment, selection bias risk, Simpson's paradox findings

**Pitfalls to flag explicitly in the report**: correlation ≠ causation, selection/survivorship bias, Simpson's paradox, regression to the mean, multiple-comparisons inflation (Bonferroni/FDR if >5 tests), averaging-of-averages error.

## Phase 5: Encode (Visualization)

**Cleveland-McGill hierarchy** (most→least accurate): position on common scale > position on non-aligned scale > length > angle/slope > area > volume > color saturation > hue. Default to position-based encodings.

**Tufte principles**: maximize data-ink ratio, eliminate chartjunk, no 3D, bars must start at zero (line charts may truncate when zero is irrelevant). *Exception*: narrow-range numerics like conversion rates 2.0%–2.4% may use a broken-axis indicator with explicit caption note.

**Knaflic principle**: **annotate the insight, not the data**. Every chart title states the finding: *"Q4 revenue grew 43%, driven by enterprise segment"* — not *"Revenue by quarter."*

**Encoding rules**
- Categorical → qualitative palette (Okabe-Ito or ColorBrewer Set2); ordinal → sequential (Viridis); signed → diverging (RdBu)
- Small multiples beat multi-series line charts with >4 series
- Pie charts: only for parts-of-whole, ≤5 slices, and only when a bar chart isn't better (it usually is)
- Log scale when data spans >2 orders of magnitude; label it clearly
- Always: axis labels with units, legend, source note, n= in subtitle
