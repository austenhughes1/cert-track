# Phase 3 extraction spike

The spike picks the free Workers AI models for bulk import. You drop 20 to 30 real certificates into a local folder, write the correct answer for each, and score two or three text models and one vision model with `bin/rails certtrack:eval_extraction`. The winners go into `EXTRACTION_MODEL` and `EXTRACTION_VISION_MODEL`. Until `EXTRACTION_MODEL` is set, imports stop at the AI step with "set EXTRACTION_MODEL".

**The bar.** A model passes when type, holder name, completed date and expiry date are each right on at least 90% of the expected certificates. If no free model passes, you choose: keep the review queue as the safety net (`AUTO_ACCEPT_ENABLED=false`, the default), or switch to the paid Anthropic fallback (PLAN.md, Phase 3).

**Privacy.** The samples hold personal data. `test/fixtures/import_samples/` is gitignored, so the files and answers never reach GitHub. Running the eval sends each sample's OCR text, and page images in vision runs, to the provider you name: Cloudflare Workers AI for the spike. Run it with `anthropic` only if you've decided Anthropic may see these certificates.

## 1. Add samples

Put the files directly in `test/fixtures/import_samples/` (subfolders are ignored). Aim for a mix like the real backlog:

- clean PDFs, and scanned PDFs with no text layer
- phone photos, including at least one iPhone HEIC, one rotated and one slightly blurry
- one PDF holding several certificates, ideally with a cover sheet or course outline page
- several types from your master list, and a card that prints an expiry date

The eval scores PDF, JPG, PNG, WEBP and HEIC files. It skips zips, so unzip the files you want scored. The Phase 3 acceptance run checks zips separately.

Next to each file, write the correct answer as `<same name>.expected.json`: `ortiz_osha30.pdf` gets `ortiz_osha30.expected.json`. It uses the shape the model must return:

```json
{
  "certificates": [
    {
      "pages": [1],
      "holder_name": "Juan A. Ortiz",
      "certificate_type_code": "OSHA30",
      "certificate_name_as_printed": "OSHA 30-Hour Construction Industry Outreach Training",
      "issuer": "Example Safety Training LLC",
      "certificate_issuer_code": null,
      "certificate_number": "30-1234567",
      "verification_code": "30-1234567",
      "verification_url": "examplesafety.com/verify",
      "completed_on": "2025-03-14",
      "expires_on": null,
      "confidence": 1,
      "notes": null
    }
  ],
  "non_certificate_pages": []
}
```

How to fill it in:

- **One entry per certificate.** A PDF with three certificates has three entries. The front and back of one card scanned into one file are one entry with `"pages": [1, 2]`. Two separate photos of the card are two files, each with its own entry.
- **`pages`**: 1-indexed page numbers in the file. A photo is `[1]`.
- **`holder_name`**: the name as printed. Case, punctuation and middle initials don't matter: "ORTIZ, JUAN A." matches "Juan Ortiz".
- **`certificate_type_code`**: the code from your master list, or `null` if the certificate isn't on it. The eval matches against the master list in your **development** database, so make sure it has the same codes as production. To list them, run `bin/rails runner 'CertificateType.active.ordered.each { |t| puts "#{t.code}  #{t.name}" }'`.
- **`completed_on`**: the completion or issue date, as `YYYY-MM-DD`.
- **`expires_on`**: the expiry date printed on the certificate. If none is printed but a validity period is ("valid for 2 years"), `completed_on` plus that period. If neither is printed, `completed_on` plus 2 years. OSHA 10 and 30 never expire, so they stay `null` unless a date is printed; so does a certificate that explicitly says it has no expiration (owner's rule, Nov 5, 2026). The model reports only a printed date and any stated period (`validity_months`); the score compares the expiry the pipeline works out from them.
- **`certificate_number`**: as printed, or `null`. This field is reported but doesn't count toward the bar.
- **`non_certificate_pages`**: pages that aren't certificates, such as cover sheets, course outlines and blank backs.
- `certificate_name_as_printed`, `issuer`, `confidence` and `notes` aren't scored. Fill them in or leave them `null`.

Three more fields describe how the certificate is verified (Phase 3b). They are scored and reported on their own, and don't count toward the 90% bar:

- **`certificate_issuer_code`**: the code of the issuer from your issuer list, or `null` if the issuer isn't on it. Upper or lower case doesn't matter. The model gets the active issuers from your **development** database, like the master list. To list them, run `bin/rails runner 'CertificateIssuer.active.ordered.each { |i| puts "#{i.code}  #{i.name}" }'`.
- **`verification_code`**: the code printed for checking the certificate on the issuer's site, such as a certificate ID or eCard code, or `null`. It is often the same as `certificate_number`. Spaces and case don't matter.
- **`verification_url`**: a verification address printed on the certificate, as printed, or `null`. Write only what is printed: a QR code doesn't count, because the pipeline reads QR codes itself and the model never sees them. `https://`, `www.`, upper-case letters in the site name, a trailing `/` and the order of `?a=1&b=2` don't matter.

Answer files written before these fields existed still work: a certificate without one of these keys isn't scored on it, and its column shows `-`. Write `null` when you've checked and the certificate has none, so it is scored.

Write the answers from the files themselves, not from a model's output, or the score will flatter that model.

An answer file that still contains `FILL IN` (the placeholder in blank templates) anywhere, including in the three verification fields, isn't scored yet. The run lists it under "skipped", so you can score the samples you've finished while the rest wait. When you add the verification fields to an answer you've already finished, write the values or `null`, never `FILL IN`, or the whole file drops out of the run.

## 2. Set up Workers AI in your shell

The eval runs in development on your machine. It needs only the Workers AI account ID and token (DEPLOY.md section 4):

```bash
eval "$(grep -E 'CLOUDFLARE_(ACCOUNT_ID|AI_API_TOKEN)=' ~/.config/certtrack/deploy.env)"
```

Vision candidates are Llama 4 Scout, Mistral Small 3.1 and Gemma 4, which all read a test image correctly through the app's own client on Nov 4, 2026. `@cf/meta/llama-3.2-11b-vision-instruct` is not: Workers AI answers HTTP 400 "Internal Server Error" whenever an image is sent to it through the OpenAI-compatible endpoint the app uses. Its Meta license was accepted on this account on Nov 4. For a new account, or if a future run fails with a license error, accept it like this:

```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/run/@cf/meta/llama-3.2-11b-vision-instruct" \
  -H "Authorization: Bearer $CLOUDFLARE_AI_API_TOKEN" -d '{"prompt":"agree"}'
```

To check the harness itself without spending anything, run `bin/rails "certtrack:eval_extraction[fake]"`. The fake provider only understands the synthetic test layout, so real certificates score near zero. That's expected.

## 3. Run the eval

The arguments are `[provider,model,vision_model]`, with no spaces. Quote the whole task name, because zsh treats square brackets as a pattern.

Text models (pages whose OCR text is readable):

```bash
bin/rails "certtrack:eval_extraction[workers_ai,@cf/meta/llama-3.3-70b-instruct-fp8-fast]"
bin/rails "certtrack:eval_extraction[workers_ai,@cf/meta/llama-3.1-8b-instruct-fp8-fast]"
bin/rails "certtrack:eval_extraction[workers_ai,@cf/mistralai/mistral-small-3.1-24b-instruct]"
bin/rails "certtrack:eval_extraction[workers_ai,@cf/google/gemma-4-26b-a4b-it]"
```

The vision models, each scored alone. `VISION_ONLY=1` withholds the OCR text, so every page goes to the vision model as an image:

```bash
VISION_ONLY=1 bin/rails "certtrack:eval_extraction[workers_ai,@cf/meta/llama-3.3-70b-instruct-fp8-fast,@cf/meta/llama-4-scout-17b-16e-instruct]"
VISION_ONLY=1 bin/rails "certtrack:eval_extraction[workers_ai,@cf/meta/llama-3.3-70b-instruct-fp8-fast,@cf/mistralai/mistral-small-3.1-24b-instruct]"
VISION_ONLY=1 bin/rails "certtrack:eval_extraction[workers_ai,@cf/meta/llama-3.3-70b-instruct-fp8-fast,@cf/google/gemma-4-26b-a4b-it]"
```

Then run the best text model with the vision model as the third argument, the way production runs. Pages that OCR can't read go to the vision model, except blank ones, which need no AI call. Without a vision model those pages are skipped and named in the certificate's notes; a sample with nothing else readable fails with "set EXTRACTION_VISION_MODEL".

Other options:

- `SAMPLES_DIR=/path/to/folder` scores a different folder.
- Llama 4 Scout is also a text candidate (`[workers_ai,@cf/meta/llama-4-scout-17b-16e-instruct]`). One model for both text and images keeps the setup simple. To try a model that isn't in `config/ai_models.yml`, add its rates from the [pricing page](https://developers.cloudflare.com/workers-ai/platform/pricing/) first. Otherwise the run reports deliberately high default rates. That file also notes the models ruled out on Nov 4, 2026 (Gemma 3 retired, Qwen 3 never answers, plain Llama 3.1 8B refuses schemas).
- `bin/rails "certtrack:eval_extraction[anthropic]"` scores Claude Haiku 5.5 (it needs `ANTHROPIC_API_KEY` and the owner's go-ahead), and `[ollama,<model>]` scores a local Ollama model.

**Budget.** Each run uses part of the same 10,000 free daily neurons as production imports. Usage is printed at the end. For 25 samples, a rough guide is 2,500 neurons for the 70B model, 500 for the 8B model, 2,000 for Mistral Small, 700 for Gemma 4, and 1,500 to 2,500 for a vision-only run. Since Phase 3b every call also carries the issuer list and its rules, about 600 more input tokens with the 18 default issuers: about 16 neurons a call on the 70B model, 3 on the 8B and 6 on Gemma 4. Spread the runs over two UTC days, or do them before go-live. If the allocation runs out, the run stops, prints what it scored so far, and tells you to re-run after 00:05 UTC. The budget is checked before every AI call, and one file can take several: one per 24,000 characters of readable text, plus one per unreadable page (four per call for Llama 4 Scout). A file estimated to need more than the whole daily budget is refused before its first call, with a message to split it.

## 4. Read the results

```text
sample                             certs   type      holder    completed expires   number    issuer    vcode     vlink      neurons   notes
garcia_osha30.pdf                  1/1     1/1       1/1       1/1       0/1       1/1       1/1       1/1       -               98   expires: want "2027-05-01", got nil
...
Field accuracy (the bar is 90% on type, holder, completed and expires):
  type          24/25   96.0%  meets the bar
  ...
Verification fields (reported on their own, not part of the bar):
  issuer        20/22   90.9%  (reported, not part of the bar)
  vcode         15/18   83.3%  (reported, not part of the bar)
  vlink           -       -    (no answer file has verification_url yet)

Certificates: 25 expected, 25 found, 1 extra. Non-certificate pages: 3/4 identified. Errors: 0.
Usage: 26 requests, 51,200 input tokens, 6,100 output tokens, 2,610 neurons, 95 s
Verdict: below the 90% bar on expires.
```

- Each row compares one file with its answer. `certs` is the number found out of the number expected, plus extras the model invented. The notes show the first few wrong fields, the bar's fields first.
- `issuer`, `vcode` and `vlink` are the issuer code, verification code and verification address. They score the model's reply only: in the pipeline, a QR code on the certificate also names the issuer and gives the link, so imports do better than these columns on cards with a QR code.
- An expected certificate the model missed, or a file that errored, counts as wrong on every field its answer has.
- Look at the wrong fields before blaming the model. A typo in an answer file or an unreadable scan can look like a model error.

## 5. Record the scores and choose

Add a results table under Phase 3 in `docs/PLAN.md`:

```markdown
**Extraction spike results** (25 samples, Nov 2026)

| Model | Type | Holder | Completed | Expires | Issuer | Code | Link | Neurons per run | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| @cf/meta/llama-3.3-70b-instruct-fp8-fast | 96% | 92% | 92% | 88% | 91% | 83% | - | 2,610 | misses printed expiry on wallet cards |
| @cf/meta/llama-3.1-8b-instruct-fp8-fast | ... | | | | | | | | |
| @cf/meta/llama-4-scout-17b-16e-instruct (vision only) | ... | | | | | | | | |
```

Then pick the text model with the best score on the four bar fields. When two are close, take the one that uses fewer neurons: it drains a backlog faster, and break a remaining tie on the issuer and verification columns. Pick the vision model the same way.

1. Set both models in `config/deploy.yml` by uncommenting `EXTRACTION_MODEL` and `EXTRACTION_VISION_MODEL`. Check that both have rates in `config/ai_models.yml`, then commit and run `bin/kamal deploy`.
2. If no model reaches 90%, keep `AUTO_ACCEPT_ENABLED: "false"` so every import goes through the review queue. Or switch to the Anthropic fallback (DEPLOY.md section 12). That choice is the owner's.
   After switching models, an item's **Read again** button sends a file the old model misread (still in the queue, rejected or failed) through the new one. It works on whole files only. A card cut from a PDF that held several certificates is filled in by hand instead.
3. After about 100 reviewed imports, decide whether to turn on `AUTO_ACCEPT_ENABLED`.
