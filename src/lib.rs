//! Adapter for running [Restate](https://restate.dev/) services on
//! [Cloudflare Workers](https://developers.cloudflare.com/workers/).
//!
//! This crate bridges the Restate SDK's HTTP handler with the Cloudflare Workers
//! runtime by converting between their respective body types and enforcing
//! request-response protocol mode (since Workers do not support true
//! bidirectional streaming).
//!
//! # Usage
//!
//! Build a Restate [`Endpoint`], wrap it in a [`Handler`], and call
//! [`Handler::handle`] from your worker's fetch entrypoint:
//!
//! ```rust,ignore
//! use restate_sdk::prelude::Endpoint;
//! use restate_worker::Handler;
//!
//! let endpoint = Endpoint::builder()
//!     .bind(my_service.serve())
//!     .build();
//!
//! let handler = Handler::new(endpoint);
//! let response = handler.handle(request)?;
//! ```

use http::{Request, Response};
use http_body_util::BodyExt;
use restate_sdk::prelude::{Endpoint, HandleOptions, ProtocolMode};
use worker::{Body, Result};

/// HTTP handler that forwards requests to a Restate [`Endpoint`].
///
/// Wraps a Restate endpoint and adapts it to the Cloudflare Workers runtime.
/// Requests are processed using [`ProtocolMode::RequestResponse`] because
/// Cloudflare Workers buffer the entire request body before passing it to the
/// worker, making bidirectional streaming impossible.
pub struct Handler {
    endpoint: Endpoint,
}

impl Handler {
    /// Creates a new handler backed by the given Restate endpoint.
    pub fn new(endpoint: Endpoint) -> Self {
        Self { endpoint }
    }

    /// Processes an incoming HTTP request through the Restate endpoint.
    ///
    /// Delegates to [`Endpoint::handle_with_options`] with
    /// [`ProtocolMode::RequestResponse`], then converts the response body into
    /// a Workers-compatible [`Body`].
    pub fn handle(&self, req: Request<Body>) -> Result<Response<Body>> {
        let response = self.endpoint.handle_with_options(
            req,
            HandleOptions {
                protocol_mode: ProtocolMode::RequestResponse,
            },
        );

        let (parts, body) = response.into_parts();
        let body = Body::from_stream(body.into_data_stream())?;

        Ok(Response::from_parts(parts, body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handler_from_endpoint() {
        let endpoint = Endpoint::builder().build();
        let _handler = Handler::new(endpoint);
    }
}
