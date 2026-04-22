# Test Fixtures

Real fast5 / pod5 fixtures are not checked in (file-size, format-proprietary).
To run full end-to-end tests locally, organize inputs like this:

```
test/fixtures/
  fast5_rna002/   # ~5 small multi-read fast5 files from an RNA002 run
  pod5_rna004/    # ~5 small pod5 files from an RNA004 run
  pod5_rna002/    # ~5 pod5 files from a newer RNA002 run (cross-format test)
```

## Obtaining Test Data

- ONT public data: https://github.com/nanoporetech/ont_open_datasets
- EPI2ME example data: downloadable from EPI2ME Labs
- Keep fixture files small (<100 MB per directory) by subsetting original runs.

## Running E2E Tests

After obtaining fixtures:

```bash
# From the repo root:
./prep_drs.sh --sample test_rna002 --input test/fixtures/fast5_rna002 \
  --kit rna002 --output /tmp/drs_test --copy --keep-tmp
./prep_drs.sh --sample test_rna004 --input test/fixtures/pod5_rna004 \
  --kit rna004 --output /tmp/drs_test --copy --keep-tmp
```

Expected: each sample has `fastq/pass.fq.gz`, `blow5/nanopore.drs.blow5`,
and the raw file directory populated.

Run `slow5tools quickcheck /tmp/drs_test/test_rna002/blow5/nanopore.drs.blow5`
and `gzip -t /tmp/drs_test/test_rna002/fastq/pass.fq.gz` as integrity confirmation.

E2E tests require an NVIDIA GPU and all bundled tools (run via Docker image).
