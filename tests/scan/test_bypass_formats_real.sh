#!/usr/bin/env bash
# ^ see doc:docs/bypass-detection-scenarios.md; the credential formats and tampering rows the catalog file left Undecided, against the real scanners
# ^ invariant each test pins the hook's current answer, a sample both scanners pass included; a test going red means the behaviour changed
# ^ why Expected stays Block for a sample the hook passes, not Allow; its report row reads FAIL and the gap shows in the CI table
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/scan/catalog_helpers.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/catalog_helpers.sh"

UPPER=ABCDEFGHIJKLMNOPQRSTUVWXYZ
LOWER=abcdefghijklmnopqrstuvwxyz
DIGITS=0123456789
ALNUM="$UPPER$LOWER$DIGITS"
URLSAFE="$ALNUM-_"
B64="$ALNUM+/"
HEX=0123456789abcdef

# ^ security samples are built at run time from fragments and these characters => the tree holds no credential-looking literal
# ^ why a seeded generator, not /dev/urandom; an entropy filter of a built-in rule drops some random values, a fixed sample never flakes
# ^ invariant det_chars COUNT CHARSET SEED prints COUNT characters of CHARSET; the loop runs COUNT times, COUNT is at most 200
det_chars() {
    local n="$1" set="$2" seed="$3" out="" i
    [ "$n" -ge 1 ] && [ "$n" -le 200 ] || return 1
    for ((i = 0; i < n; i++)); do
        seed=$(((seed * 1103515245 + 12345) % 2147483648))
        out+="${set:$(((seed / 65536) % ${#set})):1}"
    done
    printf '%s' "$out"
}
b64url() { base64 | tr -d '=\n' | tr '+/' '-_'; }
uuid_like() { printf '%s-%s-4%s-a%s-%s' "$(det_chars 8 "$HEX" "$1")" "$(det_chars 4 "$HEX" "$(($1 + 1))")" "$(det_chars 3 "$HEX" "$(($1 + 2))")" \
    "$(det_chars 3 "$HEX" "$(($1 + 3))")" "$(det_chars 12 "$HEX" "$(($1 + 4))")"; }

# ^ invariant one sample per fresh repository => each verdict is the sample's own; a failed step returns 1 and leaves no stale RC
commit_sample() {
    new_repo "$1" || return 1
    stage_file "$2" "$3" || return 1
    commit_cap "$1"
}
# ^ invariant commit_files REPO PATH CONTENT [PATH CONTENT]... stages every pair in one fresh repository and commits once
commit_files() {
    local repo="$1"
    shift
    new_repo "$repo" || return 1
    while [ "$#" -ge 2 ]; do
        stage_file "$1" "$2" || return 1
        shift 2
    done
    commit_cap "$repo"
}

# ^ coupled lib/scan/report.sh prints "<scanner> <detector> (match) <path>:<line>"; the quoted path matches literally
# ^ invariant rows_at PATH prints at most 3 report rows of the last commit naming PATH; a batched commit holds many rows
# ^ why || true, not a bare pipe; grep rc 1 means no row (an empty answer), head closing the pipe early must not fail the call
rows_at() { printf '%s\n' "$ERR" | grep -F -- " $1" | head -n 3 || true; }
# ^ invariant args = scanner, detector, path, label, line (default 1); a non-digit or the end must follow the line, :1 never matches :10
assert_row() {
    local line="${5:-1}" end='([^0-9]|$)'
    [[ $ERR =~ $1\ +$2\ \(match\)\ +"$3:$line"$end ]] || fail "$4: no $1 row for $2 at $3:$line; rows at $3: [$(rows_at "$3")]; output starts [${ERR:0:200}]"
}
# ^ invariant args = path, label, line (default 1); any scanner and detector
assert_any_row() {
    local line="${3:-1}" end='([^0-9]|$)'
    [[ $ERR =~ (betterleaks|trufflehog)\ +[^\ ]+\ \(match\)\ +"$1:$line"$end ]] || fail "$2: no finding at $1:$line; rows at $1: [$(rows_at "$1")]; output starts [${ERR:0:200}]"
}
assert_no_row() {
    case "$ERR" in *" $1:"*) fail "$2: unexpected finding at $1: [$(rows_at "$1")]" ;; esac
    return 0
}

# ^ invariant args = catalog id, Expected, command, path prefix; one catalog row for a sample of a batched commit
# ^ why the Actual comes from the sample's rows, not the exit code; the exit code belongs to the whole batch and a bare pass would read Blocked
# ^ invariant a commit stopped by something other than findings (nothing scanned, an error) keeps its own RC and ERR
catalog_sample() {
    local saved_rc="$RC" saved_err="$ERR" rows
    if [[ $ERR == *"a scanner did not complete"* || $ERR == *"nothing was decided"* ]]; then
        # ^ why Error, not Allowed; an unfinished scan says nothing about a sample without a row; the text has no hook prefix and catalog_actual reads Error
        RC=1 ERR="the scan was incomplete, the sample has no verdict"
    elif [[ $ERR == *"potential secret(s)"* ]]; then
        rows="$(rows_at "$4")"
        if [ -n "$rows" ]; then
            RC=1 ERR="git-secret-guard: potential secret(s) $rows"
        else
            RC=0 ERR=""
        fi
    fi
    catalog "$1" "$2" "$3"
    RC="$saved_rc" ERR="$saved_err"
}

# ^ invariant a gap is a sample the hook scanned and let through; exit 0 and only the pass line, never a skipped scan
assert_passes_scanned() {
    assert_rc 0 "$1 commits"
    assert_pass_line_only "$ERR" "$1 the hook scanned it and found nothing"
}

test_real_formats_a04_a_putty_ppk_private_key_is_blocked_by_our_rule() {
    need_real_tools
    commit_sample a04 id.ppk "$(printf 'PuTTY-User-Key-File-%s: ssh-ed25519\nEncryption: none\nComment: deploy\nPublic-Lines: 2\n%s\n%s\nPrivate-Lines: 1\n%s\nPrivate-MAC: %s' \
        3 "$(det_chars 64 "$B64" 11)" "$(det_chars 20 "$B64" 12)" "$(det_chars 44 "$B64" 13)" "$(det_chars 64 "$HEX" 14)")" || return 1
    catalog A04-ppk Block 'git commit (id.ppk, an unencrypted PuTTY key)'
    assert_blocked A04-ppk
    assert_row betterleaks putty-private-key id.ppk A04-ppk
}

test_real_formats_a05_a_slack_bot_token_and_a_webhook_url_are_blocked() {
    need_real_tools
    local tok hook
    tok="$(printf '%s%s-%s-%s-%s' xox b "$(det_chars 12 "$DIGITS" 21)" "$(det_chars 13 "$DIGITS" 22)" "$(det_chars 24 "$ALNUM" 23)")"
    hook="$(printf 'https://hooks.%s.com/services/T%s/B%s/%s' slack "$(det_chars 10 "$UPPER$DIGITS" 24)" "$(det_chars 10 "$UPPER$DIGITS" 25)" "$(det_chars 24 "$ALNUM" 26)")"
    # ^ why one commit, not one per sample; each sample sits in its own directory and has its own rows
    commit_files a05 a05a/slack.env "SLACK_TOKEN=$tok" a05b/notify.yml "webhook: $hook" || return 1
    assert_blocked A05
    catalog_sample A05-token Block 'git commit (slack.env with a fake xoxb- token)' a05a/
    assert_row betterleaks slack-bot-token a05a/slack.env A05-token
    assert_row trufflehog Slack a05a/slack.env A05-token
    catalog_sample A05-webhook Block 'git commit (notify.yml with a fake Slack webhook URL)' a05b/
    assert_row betterleaks slack-webhook-url a05b/notify.yml A05-webhook
    assert_row trufflehog SlackWebhook a05b/notify.yml A05-webhook
    no_leak "$tok"
    no_leak "${hook##*/}"
}

test_real_formats_a06_azure_storage_key_client_secret_and_sas_tokens_are_blocked() {
    need_real_tools
    local key secret sig
    key="$(det_chars 86 "$B64" 31)=="
    secret="$(printf '%s%s%s~%s' "$(det_chars 3 "$ALNUM" 33)" 7 Q "$(det_chars 34 "$ALNUM._-" 34)")"
    sig="$(det_chars 43 "$ALNUM" 35)"
    # ^ why one commit, not one per sample; each sample sits in its own directory and has its own rows
    commit_files a06 \
        a06a/storage.config "$(printf 'conn = "DefaultEndpointsProtocol=https;AccountName=acct%s;Account%s=%s;EndpointSuffix=core.windows.net"' \
            "$(det_chars 6 "$LOWER$DIGITS" 32)" Key "$key")" \
        a06b/app.env "AZURE_CLIENT_SECRET=\"$secret\"" \
        a06c/blob.txt "$(printf 'url = "https://acct.blob.core.windows.net/c/f.txt?sv=2022-11-02&ss=b&srt=sco&sp=rl&se=2030-01-01T00:00:00Z&spr=https&si%s=%s%%3D"' g "$sig")" \
        a06d/blob.txt "$(printf 'url = "https://acct.blob.core.windows.net/c/f.txt?sv=2022-11-02&sp=r&st=2024-01-01T00:00:00Z&se=2030-01-01T00:00:00Z&sr=b&si%s=%s%%3D"' g "$sig")" || return 1
    assert_blocked A06
    catalog_sample A06-storage Block 'git commit (a storage connection string with a fake account key)' a06a/
    assert_row betterleaks azure-storage-account-key a06a/storage.config A06-storage
    assert_row trufflehog AzureStorage a06a/storage.config A06-storage
    catalog_sample A06-client-secret Block 'git commit (app.env with a fake Entra ID client secret)' a06b/
    assert_row trufflehog Azure a06b/app.env A06-client-secret
    catalog_sample A06-sas-account Block 'git commit (blob.txt, a blob URL with an account SAS)' a06c/
    assert_row betterleaks azure-sas-signature a06c/blob.txt A06-sas-account
    catalog_sample A06-sas-service Block 'git commit (blob.txt, a blob URL with a service SAS)' a06d/
    assert_row trufflehog AzureSasToken a06d/blob.txt A06-sas-service
    assert_row betterleaks azure-sas-signature a06d/blob.txt A06-sas-service
    no_leak "$key"
    no_leak "$secret"
    no_leak "$sig"
}

test_real_formats_a07_connection_strings_with_a_password_are_blocked() {
    need_real_tools
    local pw
    pw="$(det_chars 20 "$ALNUM" 41)"
    # ^ why one commit, not one per sample; each sample sits in its own directory and has its own rows
    commit_files a07 \
        a07a/jdbc.properties "url=jdbc"":postgresql""://db.example.com:5432/app?user=app&pass""word=$pw" \
        a07b/db.config "conn = \"Server=tcp:db.example.com,1433;Database=app;User ID=app;Pass""word=$pw;\"" \
        a07c/pg.env "DATABASE_URL=postgres""://app"":$pw@db.example.com:5432/app" || return 1
    assert_blocked A07
    catalog_sample A07-jdbc Block 'git commit (a JDBC URL with a password parameter)' a07a/
    assert_row trufflehog JDBC a07a/jdbc.properties A07-jdbc
    catalog_sample A07-sqlserver Block 'git commit (a SQL Server connection string with a password)' a07b/
    assert_row trufflehog SQLServer a07b/db.config A07-sqlserver
    assert_row betterleaks generic-password a07b/db.config A07-sqlserver
    catalog_sample A07-postgres Block 'git commit (a Postgres URI with a password)' a07c/
    assert_row trufflehog Postgres a07c/pg.env A07-postgres
    no_leak "$pw"
}

test_real_formats_a08_a_jwt_and_bearer_headers_are_blocked() {
    need_real_tools
    local jwt bearer
    jwt="$(printf '{"alg":"HS256","typ":"JWT"}' | b64url).$(printf '{"sub":"%s","iat":1700000000}' "$(det_chars 8 "$DIGITS" 51)" | b64url).$(det_chars 43 "$URLSAFE" 52)"
    bearer="$(det_chars 40 "$ALNUM" 53)"
    # ^ why one commit, not one per sample; each sample sits in its own directory and has its own rows
    commit_files a08 \
        a08a/session.txt "jwt = \"$jwt\"" \
        a08b/call.sh "curl -H \"Authorization: Bearer $bearer\" https://api.example.com/" \
        a08c/client.py "headers = {\"Authorization\": \"Bearer $bearer\"}" \
        a08d/request.http "$(printf 'GET /v1 HTTP/1.1\nAuthorization: Bearer %s' "$bearer")" || return 1
    assert_blocked A08
    catalog_sample A08-jwt Block 'git commit (session.txt with a fake HS256 JWT)' a08a/
    assert_row betterleaks jwt a08a/session.txt A08-jwt
    catalog_sample A08-bearer-curl Block 'git commit (call.sh, a curl command with a bearer header)' a08b/
    assert_row betterleaks curl-auth-header a08b/call.sh A08-bearer-curl
    catalog_sample A08-bearer-code Block 'git commit (client.py, a bearer header in code)' a08c/
    assert_row betterleaks authorization-bearer-token a08c/client.py A08-bearer-code
    catalog_sample A08-bearer-http Block 'git commit (request.http, a bearer header in an HTTP request file)' a08d/
    assert_row betterleaks authorization-bearer-token a08d/request.http A08-bearer-http 2
    no_leak "${jwt##*.}"
    no_leak "$bearer"
}

test_real_formats_a09_a_password_in_application_properties_is_blocked() {
    need_real_tools
    local pw
    pw="$(det_chars 24 "$ALNUM" 61)"
    commit_sample a09 src/main/resources/application.properties "$(printf 'spring.datasource.username=app\nspring.datasource.pass%s=%s' word "$pw")" || return 1
    catalog A09-properties Block 'git commit (application.properties with spring.datasource.password)'
    assert_blocked A09-properties
    assert_row betterleaks generic-password src/main/resources/application.properties A09-properties 2
    no_leak "$pw"
}

test_real_formats_a10_a_user_name_and_password_in_a_url_are_blocked() {
    need_real_tools
    local pw
    pw="$(det_chars 20 "$ALNUM" 71)"
    commit_sample a10 deploy.cfg "remote = \"https""://deploy"":$pw@git.example.com/team/repo.git\"" || return 1
    catalog A10 Block 'git commit (deploy.cfg, a user name and password before the host of an https URL)'
    assert_blocked A10
    assert_row trufflehog URI deploy.cfg A10
    no_leak "$pw"
}

# ^ external betterleaks 1.9.0 generic-password needs passw, psw or a _pw suffix, generic-api-key secret, token, key, auth, ...; ours the rest
test_real_formats_a11_a_password_under_other_variable_names() {
    need_real_tools
    local spec name rule value
    local -a specs=(generic-password/password generic-password/db_password generic-password/passwd generic-password/admin_pw
        generic-api-key/secret generic-api-key/client_secret generic-api-key/auth_token generic-api-key/credentials generic-api-key/private_key
        password-assignment/pass password-assignment/pwd password-assignment/pw password-assignment/db_pass password-assignment/userpass)
    local -a args=()
    value="$(det_chars 28 "$ALNUM" 81)$(det_chars 4 "$DIGITS" 82)"
    # ^ why one commit, not one per name; each name sits in its own directory and keeps the settings.py basename
    for spec in "${specs[@]}"; do
        name="${spec#*/}"
        args+=("a11-$name/settings.py" "$name = \"$value\"")
    done
    commit_files a11-names "${args[@]}" || return 1
    assert_blocked A11-names
    for spec in "${specs[@]}"; do
        rule="${spec%%/*}"
        name="${spec#*/}"
        catalog_sample "A11-$name" Block "git commit (settings.py: $name = <32 characters>)" "a11-$name/"
        assert_row betterleaks "$rule" "a11-$name/settings.py" "A11-$name"
    done
    no_leak "$value"
}

test_real_formats_a11_our_password_rule_covers_the_usual_assignment_forms() {
    need_real_tools
    local pw f
    pw="$(det_chars 14 "$ALNUM" 91)7!"
    commit_files a11-forms \
        p/app.env "DB_PASS=$pw" \
        p/compose.yml "  pwd: $pw" \
        p/quoted.yml "  pass: '$pw'" \
        p/conf.json "{\"pwd\": \"$pw\", \"user\": \"app\"}" \
        p/db.properties "app.db.pass=$pw" \
        p/main.go "pw := \"$pw\"" \
        p/conf.php "'pass' => '$pw'," \
        p/root.env "MYSQL_ROOT_PASS""WORD=$pw" \
        p/list.yml "- pass: $pw" || return 1
    catalog A11-forms Block 'git commit (a password under pass, pwd or *_PASSWORD in env, YAML, JSON, properties, Go and PHP files)'
    assert_blocked A11-forms
    for f in app.env compose.yml quoted.yml conf.json db.properties main.go conf.php root.env list.yml; do
        assert_any_row "p/$f" "A11-forms"
    done
    for f in quoted.yml conf.json main.go conf.php; do
        assert_row betterleaks password-assignment "p/$f" "A11-forms"
    done
    for f in app.env compose.yml db.properties list.yml; do
        assert_row betterleaks password-assignment-bare "p/$f" "A11-forms"
    done
    no_leak "$pw"
}

# ^ invariant a quoted value is a literal; dots, slashes, a year after a word or a leading $ or . must not make a real password pass
test_real_formats_realistic_quoted_passwords_and_a_uuid_bearer_token_are_blocked() {
    need_real_tools
    local -a vals=("My"".Sec""ret2024" "Welc""ome.Home1" "Spr""ing/2024x" "Abc""123/def456" "hunt""er_2024" "sum""mer-2024" "qwer""ty-12345"
        "adm""in_123" '$'"ecr""et2024!" ".hid""den9Pw" "Welc""ome1" "P@""ssw0rd" "Pass""word1" "Sum""mer24!")
    local -a names=(db_pass pwd pw)
    local -a args=()
    local i
    for i in "${!vals[@]}"; do
        args+=("q/p$i.py" "${names[$((i % 3))]} = \"${vals[$i]}\"")
    done
    args+=("q/token.http" "Authorization: Bear""er $(uuid_like 301)")
    commit_files a11-real "${args[@]}" || return 1
    catalog A11-realistic Block 'git commit (realistic quoted passwords and a UUID bearer token)'
    assert_blocked A11-realistic
    for i in "${!vals[@]}"; do
        assert_row betterleaks password-assignment "q/p$i.py" "A11-realistic"
    done
    assert_row betterleaks authorization-bearer-token q/token.http A11-realistic
}

# ^ invariant every line here looks like a credential to a careless rule; the commit must pass with only the pass line
test_real_formats_placeholders_templates_paths_and_prose_still_commit() {
    need_real_tools
    # shellcheck disable=SC2016
    commit_files fp \
        n/placeholders.py "$(printf 'pass = "changeme"\npass = "changeme123"\npwd = "<password>"\npass = "${DB_PASS}"\npw = "{{ .Values.pass }}"\npass = "********"\npass = "xxxxxxxxxxxx"\npass = "your_password_1"\npass = "12345678"\npass = "hunterhunter"')" \
        n/code.py "$(printf 'password = os.getenv("DB_PASSWORD")\npass = os.environ["PASS"]\npass = get_secret("db")\nbypass = "%s"' "$(det_chars 14 "$ALNUM" 101)7x")" \
        n/shell.env "$(printf 'PWD=/home/user/project/src\nOLDPWD=/tmp/work/build')" \
        n/flags.yml "$(printf 'pass: true\npw: 8080\ncompass: north-by-northwest-2')" \
        n/notes.md "$(printf '| C05 | Obfuscated secret: base64-encoded, split across lines | Gap |\nEnter the password: then press return.\nThe bearer of this certificate is entitled to every listed benefit.\nThe bearer token_authentication_flow_v2 is described below.\nSee bearer tokens/credentials-management-v2 for details.')" \
        n/members.js "$(printf 'const pass = user.password;\nconst pwd = process.env.DB_PWD;\nlet pw = req.body.pw;')" \
        n/refs.tf "$(printf '%s\n' 'pass = var.db_pass' 'pass = local.db_pass_v2' 'pass = self.db_password')" \
        n/refs.yml "$(printf -- '- pwd: build/out/dir\npass: refs/heads/main')" \
        n/passes.py "$(printf 'first_pass = "tokenize_v2"\nsecond_pass = "optimize-ir-3"')" \
        n/interp.txt "$(printf '%s\n' "db_pass = \"#{ENV['DB_PASS']}\"" '$db_pass = "$env:DB_PASS"' 'db_pass: "$(DB_PASS)"' "db_pass: '%env(DB_PASS)%'" \
            'db_pass = "{env.DB_PW}"' 'BUILD_PWD="$PWD/out/bin"' 'TOP_PWD="$HOME/projects"' 'root_pwd="$(git_root)/x"' \
            'db_pass: "@Microsoft.KeyVault(SecretUri=x)"')" \
        n/refs-secrets.yml "$(printf '%s\n' 'pw: arn:aws:secretsmanager:x' 'db_pass: vault:secret/data/db#pass' 'db_pass: sm://projects/p/secrets/db')" \
        n/auth.http "$(printf 'Authorization: Bearer ${API_TOKEN}\nAuthorization: Bearer <your-access-token>\nAuthorization: Bearer YOUR_ACCESS_TOKEN_GOES_HERE')" \
        n/client.py 'headers = {"Authorization": "Bearer " + token}' \
        n/sas.txt "$(printf 'url = "https://acct.blob.core.windows.net/c?sv=2022-11-02&si%s=<signature>"' g)" \
        n/hash.py "password_hash = \"$(det_chars 64 "$HEX" 102)\"" || return 1
    catalog FP Allow 'git commit (placeholders, templates, paths, getenv calls, prose and bearer templates)'
    assert_passes_scanned FP
}

test_real_formats_b02_lockfile_hashes_uuids_and_a_base64_image_commit() {
    need_real_tools
    new_repo b02 || return 1
    printf '{\n  "packages": {\n    "node_modules/x": { "integrity": "sha512-%s==" }\n  }\n}\n' "$(det_chars 86 "$B64" 111)" >package-lock.json || return 1
    printf '[[package]]\nname = "serde"\nversion = "1.0.0"\nchecksum = "%s"\n' "$(det_chars 64 "$HEX" 112)" >Cargo.lock || return 1
    printf 'id: %s\nsha256: %s\n' "$(uuid_like 113)" "$(det_chars 64 "$HEX" 118)" >ids.yml || return 1
    printf '<img src="data:image/png;base64,%s">\n' "$(det_chars 200 "$B64" 121)$(det_chars 200 "$B64" 122)$(det_chars 200 "$B64" 123)" >page.html || return 1
    gitx add . || return 1
    commit_cap B02
    catalog B02 Allow 'git commit (lockfile integrity hashes, a Cargo.lock checksum, UUID, sha256, base64 image)'
    assert_passes_scanned B02
}

# ^ invariant vendor_rows prints ID|ENV_VAR|code template (%s = key)|bare verdict|key per line; bare "pass" pins a key with no shape of its own
# ^ security the key shapes follow each vendor's published format, built from fragments and det_chars; no row is a real key
vendor_rows() {
    local u="$URLSAFE"
    printf '%s\n' \
        "anthropic-api|ANTHROPIC_API_KEY|client = Anthropic(api_key=\"%s\")|block|sk-""ant-api03-$(det_chars 93 "$u" 201)AA" \
        "anthropic-admin|ANTHROPIC_ADMIN_KEY|client = Anthropic(api_key=\"%s\")|block|sk-""ant-admin01-$(det_chars 93 "$u" 202)AA" \
        "openai-proj|OPENAI_API_KEY|client = OpenAI(api_key=\"%s\")|block|sk-""proj-$(det_chars 74 "$u" 203)T3Blbk""FJ$(det_chars 74 "$u" 204)" \
        "openai-legacy|OPENAI_API_KEY|client = OpenAI(api_key=\"%s\")|block|sk-$(det_chars 20 "$ALNUM" 205)T3Blbk""FJ$(det_chars 20 "$ALNUM" 206)" \
        "voyage|VOYAGE_API_KEY|client = voyageai.Client(api_key=\"%s\")|block|pa-$(det_chars 43 "$u" 207)" \
        "google|GEMINI_API_KEY|client = genai.Client(api_key=\"%s\")|block|AI""za$(det_chars 35 "$u" 208)" \
        "mistral|MISTRAL_API_KEY|client = Mistral(api_key=\"%s\")|pass|$(det_chars 32 "$ALNUM" 209)" \
        "cohere|COHERE_API_KEY|client = cohere.Client(api_key=\"%s\")|pass|$(det_chars 40 "$ALNUM" 210)" \
        "groq|GROQ_API_KEY|client = Groq(api_key=\"%s\")|block|gsk""_$(det_chars 52 "$ALNUM" 211)" \
        "xai|XAI_API_KEY|client = Client(api_key=\"%s\")|block|xai""-$(det_chars 80 "$ALNUM" 212)" \
        "deepseek|DEEPSEEK_API_KEY|client = OpenAI(api_key=\"%s\")|block|sk-$(det_chars 32 "$HEX" 213)" \
        "perplexity|PERPLEXITY_API_KEY|client = Perplexity(api_key=\"%s\")|block|pplx""-$(det_chars 48 "$ALNUM" 214)" \
        "together|TOGETHER_API_KEY|client = Together(api_key=\"%s\")|pass|$(det_chars 64 "$HEX" 215)" \
        "cerebras|CEREBRAS_API_KEY|client = Cerebras(api_key=\"%s\")|block|csk""-$(det_chars 48 "$LOWER$DIGITS" 216)" \
        "openrouter|OPENROUTER_API_KEY|client = OpenAI(api_key=\"%s\")|block|sk-""or-v1-$(det_chars 64 "$HEX" 217)" \
        "replicate|REPLICATE_API_TOKEN|client = replicate.Client(api_token=\"%s\")|block|r8""_$(det_chars 37 "$ALNUM" 218)" \
        "huggingface|HF_TOKEN|client = InferenceClient(token=\"%s\")|block|hf""_$(det_chars 34 "$UPPER$LOWER" 219)" \
        "langsmith|LANGSMITH_API_KEY|client = Client(api_key=\"%s\")|block|lsv2""_pt_$(det_chars 32 "$HEX" 220)_$(det_chars 10 "$HEX" 221)" \
        "elevenlabs|ELEVENLABS_API_KEY|client = ElevenLabs(api_key=\"%s\")|block|sk""_$(det_chars 48 "$HEX" 222)" \
        "deepgram|DEEPGRAM_API_KEY|client = DeepgramClient(api_key=\"%s\")|pass|$(det_chars 40 "$HEX" 223)" \
        "assemblyai|ASSEMBLYAI_API_KEY|aai.settings.api_key = \"%s\"|pass|$(det_chars 32 "$HEX" 224)" \
        "stability|STABILITY_API_KEY|client = StabilityClient(api_key=\"%s\")|block|sk-$(det_chars 48 "$ALNUM" 225)" \
        "nvidia|NVIDIA_API_KEY|client = OpenAI(api_key=\"%s\")|block|nvapi""-$(det_chars 64 "$u" 226)" \
        "wandb|WANDB_API_KEY|wandb.login(key=\"%s\")|pass|$(det_chars 40 "$HEX" 227)" \
        "pinecone|PINECONE_API_KEY|pc = Pinecone(api_key=\"%s\")|block|pcsk""_$(det_chars 5 "$ALNUM" 228)_$(det_chars 63 "$ALNUM" 229)" \
        "pinecone-legacy|PINECONE_API_KEY|pc = Pinecone(api_key=\"%s\")|pass|$(uuid_like 230)" \
        "azure-openai|AZURE_OPENAI_API_KEY|client = AzureOpenAI(api_key=\"%s\", azure_endpoint=\"https://res.openai.azure.com\")|pass|$(det_chars 32 "$HEX" 235)"
}

# ^ invariant one commit per key shape holds the bare line, the .env line and the code line; each form needs its own finding row
test_real_formats_ai_vendor_api_keys_in_three_forms() {
    need_real_tools
    local rows id env code bare key
    local -a args=() keys=()
    rows="$(vendor_rows)" || return 1
    # ^ why one commit, not 27; each shape sits in its own directory and a failed assertion names the shape and the file
    while IFS='|' read -r id env code bare key; do
        [ -n "$id" ] || continue
        # shellcheck disable=SC2059
        args+=("$id/bare.txt" "$key" "$id/app.env" "$env=$key" "$id/main.py" "$(printf "$code" "$key")")
        keys+=("$key")
    done <<<"$rows"
    commit_files v-all "${args[@]}" || return 1
    assert_blocked AI-vendors
    while IFS='|' read -r id env code bare key; do
        [ -n "$id" ] || continue
        catalog_sample "AI-$id" Block "git commit ($id key bare, as $env=... and in a client call)" "$id/"
        assert_any_row "$id/app.env" "AI-$id .env"
        assert_any_row "$id/main.py" "AI-$id code"
        if [ "$bare" = block ]; then assert_any_row "$id/bare.txt" "AI-$id bare"; else assert_no_row "$id/bare.txt" "AI-$id bare"; fi
    done <<<"$rows"
    for key in "${keys[@]}"; do no_leak "$key"; done
}

test_real_formats_ai_an_azure_openai_key_next_to_its_endpoint_is_blocked() {
    need_real_tools
    local key
    key="$(det_chars 32 "$HEX" 241)"
    commit_files azure-openai-ctx \
        a/request.http "$(printf 'POST https://res.cognitiveservices.azure.com/openai/deployments/gpt/chat/completions\napi-key: %s' "$key")" \
        a/settings.env "AZURE_OPENAI_KEY=$key" || return 1
    catalog AI-azure-openai-context Block 'git commit (an api-key header next to the endpoint, AZURE_OPENAI_KEY=...)'
    assert_blocked AI-azure-openai-context
    assert_row betterleaks azure-openai-api-key-header a/request.http AI-azure-openai-context 2
    assert_row betterleaks azure-openai-api-key a/settings.env AI-azure-openai-context
    no_leak "$key"
}

# ^ invariant a plain UUID and a hex hash with no vendor context are ids, not keys; they must commit
test_real_formats_ai_a_plain_uuid_and_a_hex_hash_without_context_commit() {
    need_real_tools
    commit_files ai-fp \
        f/ids.yml "$(printf 'request_id: %s\ntrace = "%s"' "$(uuid_like 251)" "$(uuid_like 256)")" \
        f/hashes.txt "$(printf 'checksum = "%s"\nETag: "%s"\n%s' "$(det_chars 32 "$HEX" 261)" "$(det_chars 32 "$HEX" 262)" "$(det_chars 32 "$HEX" 263)")" || return 1
    catalog AI-fp Allow 'git commit (a plain UUID and a hex hash with no vendor context)'
    assert_passes_scanned AI-fp
}

# ^ security the shipped rule file is user-writable; a match-all allowlist in it would mute betterleaks, the hook checks its SHA-256 against the settings (#26)
# ^ invariant both commits fail closed before betterleaks starts => "nothing was scanned" blocks them; trufflehog still runs and is not what this pins
test_real_formats_c03_an_edited_rule_file_blocks_the_commit() {
    need_real_tools
    local key key_rc key_err
    key="$(fake_aws_key)"
    printf '\n[allowlist]\nregexes = ['"'''"'.*'"'''"']\n' >>"$SHARE/lib/scan/betterleaks-rule.toml" || return 1
    commit_sample c03a ids.env "AWS_ACCESS_KEY_ID=$key" || { restore_hook_files; return 1; }
    key_rc="$RC" key_err="$ERR"
    commit_sample c03b gh.env "$(token_line)" || { restore_hook_files; return 1; }
    restore_hook_files || return 1
    catalog C03-rule-file-token Detect 'append a match-all [allowlist] to <share>/lib/scan/betterleaks-rule.toml && git commit (a GitHub token)'
    assert_blocked_unscanned C03-rule-file-token
    assert_contains "$ERR" "betterleaks: the shipped rule file" "C03 the edited rule file is named"
    assert_contains "$ERR" "reinstall git-secret-guard from a checkout or a release" "C03 the recovery is named"
    no_leak "$(fake_github_token)"
    RC="$key_rc" ERR="$key_err"
    catalog C03-rule-file-key Detect 'append a match-all [allowlist] to <share>/lib/scan/betterleaks-rule.toml && git commit (a lone AWS key ID)'
    assert_blocked_unscanned C03-rule-file-key
    assert_contains "$ERR" "betterleaks: the shipped rule file" "C03 the edited rule file is named for the lone key ID too"
    no_leak "$key"
}

# ^ security the settings file is sourced; a line ending the shell skips the scan, a broken tool path or timeout fails closed
test_real_formats_c03_an_edited_settings_file() {
    need_real_tools
    use_real_tools 'exit 0'
    commit_sample c03c gh.env "$(token_line)" || return 1
    use_real_tools
    catalog C03-settings-exit Detect 'append "exit 0" to <share>/settings && git commit (a GitHub token)'
    assert_hook_never_ran C03-settings-exit
    printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/noop-scanner" && chmod 755 -- "$SANDBOX/noop-scanner" || return 1
    use_real_tools "TRUFFLEHOG_BIN=$SANDBOX/noop-scanner"
    commit_sample c03d gh.env "$(token_line)" || return 1
    catalog C03-settings-trufflehog Block 'settings TRUFFLEHOG_BIN=<script exiting 0> && git commit'
    assert_rc 1 "C03 a no-op trufflehog blocked"
    assert_contains "$ERR" "trufflehog: did not report a completed scan" "C03 the no-op trufflehog fails closed"
    use_real_tools "BETTERLEAKS_BIN=$SANDBOX/noop-scanner"
    commit_sample c03e gh.env "$(token_line)" || return 1
    catalog C03-settings-betterleaks Block 'settings BETTERLEAKS_BIN=<script exiting 0> && git commit'
    assert_rc 1 "C03 a no-op betterleaks blocked"
    assert_contains "$ERR" "betterleaks: no report was written" "C03 the no-op betterleaks fails closed"
    # ^ hazard a real scan can finish inside 1s (macOS CI did) => the stand-in sleeps, the timeout always fires
    printf '#!/bin/sh\nexec sleep 30\n' >"$SANDBOX/slow-scanner" && chmod 755 -- "$SANDBOX/slow-scanner" || return 1
    use_real_tools "$(printf 'TRUFFLEHOG_BIN=%s\nSCAN_TIMEOUT_SECONDS=1' "$SANDBOX/slow-scanner")"
    commit_sample c03f gh.env "$(token_line)" || return 1
    use_real_tools
    catalog C03-settings-timeout Block 'settings SCAN_TIMEOUT_SECONDS=1, a scanner slower than that && git commit'
    assert_rc 1 "C03 a one-second timeout blocked"
    assert_contains "$ERR" "timed out after 1s" "C03 the timeout fails closed"
    no_leak "$(fake_github_token)"
}

# ^ security the hook runs no find; a no-op find first on PATH changes nothing, the token is found and the commit blocked (#25)
test_real_formats_n02_a_no_op_find_first_on_path_still_blocks_a_token() {
    need_real_tools
    mkdir -p -- "$SANDBOX/shadow-find"
    printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/shadow-find/find" && chmod 755 -- "$SANDBOX/shadow-find/find" || return 1
    set_env PATH="$SANDBOX/shadow-find:$REAL_HOME/.local/bin:$TEST_BASE_PATH"
    commit_sample n02 k.env "$(token_line)" || return 1
    catalog N02 Block 'PATH=<dir with a no-op find>:<PATH> git commit'
    assert_blocked N02
    assert_row trufflehog Github k.env N02
    assert_not_contains "$ERR" "no added lines to scan" "N02 the hook does not claim there was nothing to scan"
    no_leak "$(fake_github_token)"
}

# ^ security a no-op tool between the scanners and the verdict loses the rows; the exit status said findings => the commit blocks (#31)
# ^ invariant args = catalog id (upper case), tool name; the stand-in exits 0 and prints nothing, first on PATH
assert_lost_rows_block() {
    need_real_tools
    mkdir -p -- "$SANDBOX/shadow-$2"
    rm -f -- "$SANDBOX/ran-$2"
    printf '#!/bin/sh\n: >"%s"\nexit 0\n' "$SANDBOX/ran-$2" >"$SANDBOX/shadow-$2/$2" && chmod 755 -- "$SANDBOX/shadow-$2/$2" || return 1
    set_env PATH="$SANDBOX/shadow-$2:$REAL_HOME/.local/bin:$TEST_BASE_PATH"
    commit_sample "${1,,}" k.env "$(token_line)" || return 1
    catalog "$1" Block "PATH=<dir with a no-op $2>:<PATH> git commit"
    assert_rc 1 "$1 blocked"
    assert_not_contains "$ERR" ": no findings" "$1 no pass line"
    if gnubin_has "$2"; then
        # ^ external on macOS the hook puts GNUBIN_DIR first => this coreutils tool is the GNU one and the stand-in is never reached
        assert_no_file "$SANDBOX/ran-$2" "$1 the stand-in was never run (the recorded GNU directory comes first)"
        assert_contains "$ERR" "potential secret(s)" "$1 the findings are reported normally"
        assert_not_contains "$ERR" "none reached the report" "$1 no cross-check line"
    else
        assert_file "$SANDBOX/ran-$2" "$1 the stand-in ran, the shadow took effect"
        assert_contains "$ERR" "reported findings but none reached the report" "$1 the cross-check names the lost findings"
    fi
    no_leak "$(fake_github_token)"
}

test_real_formats_n09_a_no_op_cat_first_on_path_still_blocks_a_token() { assert_lost_rows_block N09 cat; }
test_real_formats_n10_a_no_op_sort_first_on_path_still_blocks_a_token() { assert_lost_rows_block N10 sort; }

run_file_tests
