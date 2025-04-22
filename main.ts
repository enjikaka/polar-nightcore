import { Polar } from "npm:@polar-sh/sdk";

let polar: Polar | null = null;

/**
 * Generates Headers with Access-Control-Allow-Origin.
 * If a response is passed in, the headers are cloned
 * and the CORS header set before the Headers are returned.
 */
function corsHeaders(request: Request): Headers {
  const origin = request.headers.get("origin");
  const headers = new Headers();
  const allowedOrigins = [
    "https://nightcore.app",
    "http://localhost:1337",
  ];

  if (!origin) {
    return new Headers();
  }

  if (allowedOrigins.includes(origin)) {
    headers.set("access-control-allow-origin", origin);
  }

  return headers;
}

function getPolar() {
  if (!polar) {
    const { accessToken, server } = getEnvVars();

    polar = new Polar({
      server,
      accessToken,
    });
  }

  return polar;
}

function getEnvVars(): {
  accessToken: string;
  productId: string;
  organizationId: string;
  server: "production" | "sandbox";
} {
  const envVars = [
    "POLAR_ACCESS_TOKEN",
    "POLAR_PRODUCT_ID",
    "POLAR_SERVER",
    "POLAR_ORGANIZATION_ID",
  ];

  for (const varName of envVars) {
    if (!Deno.env.get(varName)) {
      console.error(`Missing environment variable: ${varName}`);
      Deno.exit(1);
    }
  }

  return {
    accessToken: Deno.env.get("POLAR_ACCESS_TOKEN")!,
    productId: Deno.env.get("POLAR_PRODUCT_ID")!,
    organizationId: Deno.env.get("POLAR_ORGANIZATION_ID")!,
    server: Deno.env.get("POLAR_SERVER")! as "production" | "sandbox",
  };
}

async function checkoutHandler(request: Request) {
  const { productId } = getEnvVars();

  const polar = getPolar();

  const checkout = await polar.checkouts.create({
    productId,
  });

  return new Response(null, {
    status: 302,
    headers: {
      "Location": checkout.url,
    },
  });
}

async function validateKey(key: string) {
  const polar = getPolar();
  const { organizationId } = getEnvVars();

  const result = await polar.customerPortal.licenseKeys.validate({
    key,
    organizationId,
  });

  const valid = result.status === "granted" && result.limitUsage &&
    result.usage < result.limitUsage;

  return valid;
}

async function exhaustKey(key: string): Promise<boolean> {
  const polar = getPolar();
  const { organizationId } = getEnvVars();

  const result = await polar.customerPortal.licenseKeys.validate({
    key,
    organizationId,
    incrementUsage: 1,
  });

  const valid = result.status === "granted" && result.limitUsage &&
    result.usage < result.limitUsage;

  return !valid;
}

/**
 * Validate a license key provided by the user.
 * @param request
 * @returns
 */
async function validateHandler(
  request: Request,
) {
  const url = new URL(request.url);
  const key = url.searchParams.get("key");

  if (!key) {
    return new Response("Missing license key", { status: 400 });
  }

  const valid = await validateKey(key);

  const headers = corsHeaders(request);

  headers.append("content-type", "application/json");

  return new Response(JSON.stringify({ valid }), {
    status: 200,
    headers,
  });
}

/**
 * Use up a license key provided by the user.
 * @param request
 * @returns
 */
async function useHandler(
  request: Request,
) {
  const url = new URL(request.url);
  const key = url.searchParams.get("key");

  if (!key) {
    return new Response("Missing license key", { status: 400 });
  }

  const valid = await validateKey(key);

  if (valid) {
    const exhausted = await exhaustKey(key);

    if (exhausted) {
      return new Response(
        JSON.stringify({ valid: true }),
        {
          status: 200,
          headers: {
            "Content-Type": "application/json",
          },
        },
      );
    }
  }

  const headers = corsHeaders(request);

  headers.append("Content-Type", "application/json");

  return new Response(
    JSON.stringify({ message: "Licence key is not valid" }),
    {
      status: 400,
      headers,
    },
  );
}

async function rootHandler(req: Request) {
  return new Response("Welcome to the Nightcore.app Polar service on Deno.");
}

const patternsToHandlers = new Map([
  [{ pathname: "/checkout" }, checkoutHandler],
  [{ pathname: "/validate" }, validateHandler],
  [{ pathname: "/use" }, useHandler],
  [{ pathname: "/validate/:key" }, validateHandler],
  [{ pathname: "/" }, rootHandler],
]);

const routingMap: Map<URLPattern, (request: Request) => Promise<Response>> =
  new Map();

for (const [patternInput, handler] of patternsToHandlers) {
  const compiledPattern = new URLPattern(patternInput);
  routingMap.set(compiledPattern, handler);
}

Deno.serve((request: Request) => {
  if (request.method.toUpperCase() === "OPTIONS") {
    return new Response(null, { headers: corsHeaders(request) });
  }

  for (const [compiledPattern, handler] of routingMap) {
    const result = compiledPattern.exec(request.url);
    if (result) {
      return handler(request);
    }
  }

  return new Response("Not found", { status: 404 });
});
