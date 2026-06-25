// Worker de failover do Dify.
//
// Roda no route `<app_hostname>/*`. Em condicoes normais ele e' apenas um
// pass-through: repassa a requisicao para a origem (o Cloudflare Tunnel).
//
// Quando a EC2 esta desligada (janela 18h-08h / fim de semana), o connector
// `cloudflared` morre, o tunnel deixa de existir no edge e o Cloudflare devolve
// um erro de origem inacessivel na faixa 521-530 (1033 = 530). Nesse caso o
// Worker serve a pagina estatica de manutencao (HTML no bucket S3 publico)
// com HTTP 503.
//
// Obs.: `fetch(request)` a partir de um Worker que esta no proprio route vai
// para a ORIGEM (o Cloudflare previne o loop de volta ao Worker), entao isso
// nao causa recursao.

export default {
  async fetch(request, env) {
    try {
      const resp = await fetch(request);
      // 521-530 = erros gerados pelo Cloudflare quando a origem/tunnel esta
      // inacessivel (524 timeout, 530/1033 tunnel ausente, etc.). Um 5xx do
      // proprio Dify (ex.: 502 com nginx no ar) passa direto, de proposito.
      if (resp.status >= 521 && resp.status <= 530) {
        return maintenance(env);
      }
      return resp;
    } catch (e) {
      return maintenance(env);
    }
  },
};

async function maintenance(env) {
  try {
    const r = await fetch(env.MAINTENANCE_URL, { cf: { cacheTtl: 30 } });
    const html = await r.text();
    return new Response(html, {
      status: 503,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "retry-after": "120",
        "cache-control": "no-store",
      },
    });
  } catch (e) {
    // Fallback minimo caso ate o bucket esteja indisponivel.
    return new Response(
      "<!DOCTYPE html><meta charset=utf-8><title>Em manutencao</title>" +
        "<h1>Estamos em manutencao</h1><p>Volte em instantes.</p>",
      {
        status: 503,
        headers: {
          "content-type": "text/html; charset=utf-8",
          "retry-after": "120",
        },
      },
    );
  }
}
