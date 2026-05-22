# TODO

## Infrastructure

- [x] **Fixed URL** — ALB in place, DNS: `shareshot-2000439380.us-east-1.elb.amazonaws.com`
- [ ] **HTTPS** — TLS termination at ALB with ACM certificate; currently plain HTTP on port 80
- [ ] **Team access automation** — tse-sandbox blocks `0.0.0.0/0` SG rules; each member still needs a manual `/32` rule on the ALB SG (`sg-01b4bd0a407ed0fd1`)

## Auth

- [ ] **Authentication** — currently no login; anyone with the URL has owner access. Plan: Google OAuth via AWS Cognito or simple SSO, scoped to `@datadoghq.com` accounts
- [ ] **Per-user project ownership** — after auth lands, associate projects with a `ownerEmail` so the home page only shows your own projects (not the global list)

## Features

- [ ] **Real commenting UI** — the "commenter" role currently has the same canvas edit access as editor; add a dedicated comment thread / annotation overlay so commenting and editing are meaningfully distinct
- [ ] **Project search / filter** — home page lists all projects with no search; add a text filter as the project count grows
- [ ] **Pagination** — `listAllCols()` fetches all S3 objects on every page load; add cursor-based pagination before the bucket gets large
- [ ] **Image cleanup** — deleting a project only removes `sharedImageId`; intermediate upload images (`/api/images`) are never deleted; add a cleanup pass
- [ ] **Duplicate / fork project** — copy a project's canvas state into a new project

## Polish

- [ ] **Mobile view** — canvas toolbar and layout are not optimised for small screens
- [ ] **Project thumbnail** — show a small preview image on the home page cards instead of just a title
- [ ] **Share link expiry** — optionally set an expiry date on viewer/commenter/editor tokens
