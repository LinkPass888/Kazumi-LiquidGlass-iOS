import json
import os
import urllib.error
import urllib.request

REPO = os.environ.get('REPO', 'LinkPass888/Kazumi-LiquidGlass-iOS')
BRANCH = os.environ.get('HEAD_BRANCH', 'feat/liquid-glass')
TOKEN = os.environ['TOKEN']
LIMIT = 58000


def api(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request('https://api.github.com' + path, data=data, method=method)
    request.add_header('Authorization', 'token ' + TOKEN)
    request.add_header('Accept', 'application/vnd.github+json')
    if data is not None:
        request.add_header('Content-Type', 'application/json')
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode())


def main():
    pulls = api('GET', '/repos/%s/pulls?state=open&head=LinkPass888:%s' % (REPO, BRANCH))
    if not pulls:
        print('no open PR for %s' % BRANCH)
        return
    number = pulls[0]['number']
    chunks = []
    for name in ('analyze.log', 'test.log', 'build.log'):
        if not os.path.exists(name):
            continue
        text = open(name, encoding='utf-8', errors='replace').read()
        if not text.strip():
            continue
        chunks.append('## %s\n```\n%s\n```' % (name, text[-LIMIT:]))
    body = '\n\n'.join(chunks) or '(no logs)'
    if len(body) > LIMIT:
        body = body[-LIMIT:]
    posted = api('POST', '/repos/%s/issues/%d/comments' % (REPO, number), {'body': body})
    print('comment', posted['id'], len(body), 'chars')


if __name__ == '__main__':
    main()
