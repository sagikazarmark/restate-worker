# Cloudflare Worker handler for Restate

![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/sagikazarmark/restate-worker/ci.yaml?style=flat-square)
![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/sagikazarmark/restate-worker/badge?style=flat-square)

Adapter for running [Restate](https://restate.dev/) services on [Cloudflare Workers](https://developers.cloudflare.com/workers/).

This crate bridges the Restate SDK's HTTP handler with the Cloudflare Workers runtime by converting between their respective body types and enforcing request-response protocol mode (since Workers do not support true bidirectional streaming).

## Quickstart

Add the crate to your worker project:

```sh
cargo add restate-worker
```

Build a Restate `Endpoint`, wrap it in a `Handler`, and call `Handler::handle` from your worker's fetch entrypoint:

```rust
use restate_sdk::prelude::Endpoint;
use restate_worker::Handler;
use worker::*;

#[event(fetch)]
async fn fetch(req: HttpRequest, _env: Env, _ctx: Context) -> Result<http::Response<Body>> {
    let endpoint = Endpoint::builder()
        .bind(my_service.serve())
        .build();

    Handler::new(endpoint).handle(req)
}
```

## How it works

Cloudflare Workers buffer the entire request body before passing it to the worker, making bidirectional streaming impossible.
`Handler` wraps a Restate `Endpoint` and processes requests using `ProtocolMode::RequestResponse` to account for this limitation.

## License

The project is licensed under the [MIT License](LICENSE).
