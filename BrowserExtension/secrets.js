(function (root) {
  'use strict';
  // BIP39's unchanged English wordlist (MIT). Source, pinned revision and
  // attribution: Sources/SentinelPet/Secrets/BIP39_ATTRIBUTION.txt.
  const WORDS = 'abandon ability able about above absent absorb abstract absurd abuse access accident account accuse achieve acid acoustic acquire across act action actor actress actual adapt add addict address adjust admit adult advance advice aerobic affair afford afraid again age agent agree ahead aim air airport aisle alarm album alcohol alert alien all alley allow almost alone alpha already also alter always amateur amazing among amount amused analyst anchor ancient anger angle angry animal ankle announce annual another answer antenna antique anxiety any apart apology appear apple approve april arch arctic area arena argue arm armed armor army around arrange arrest arrive arrow art artefact artist artwork ask aspect assault asset assist assume asthma athlete atom attack attend attitude attract auction audit august aunt author auto autumn average avocado avoid awake aware away awesome awful awkward axis baby bachelor bacon badge bag balance balcony ball bamboo banana banner bar barely bargain barrel base basic basket battle beach bean beauty because become beef before begin behave behind believe below belt bench benefit best betray better between beyond bicycle bid bike bind biology bird birth bitter black blade blame blanket blast bleak bless blind blood blossom blouse blue blur blush board boat body boil bomb bone bonus book boost border boring borrow boss bottom bounce box boy bracket brain brand brass brave bread breeze brick bridge brief bright bring brisk broccoli broken bronze broom brother brown brush bubble buddy budget buffalo build bulb bulk bullet bundle bunker burden burger burst bus business busy butter buyer buzz cabbage cabin cable cactus cage cake call calm camera camp can canal cancel candy cannon canoe canvas canyon capable capital captain car carbon card cargo carpet carry cart case cash casino castle casual cat catalog catch category cattle caught cause caution cave ceiling celery cement census century cereal certain chair chalk champion change chaos chapter charge chase chat cheap check cheese chef cherry chest chicken chief child chimney choice choose chronic chuckle chunk churn cigar cinnamon circle citizen city civil claim clap clarify claw clay clean clerk clever click client cliff climb clinic clip clock clog close cloth cloud clown club clump cluster clutch coach coast coconut code coffee coil coin collect color column combine come comfort comic common company concert conduct confirm congress connect consider control convince cook cool copper copy coral core corn correct cost cotton couch country couple course cousin cover coyote crack cradle craft cram crane crash crater crawl crazy cream credit creek crew cricket crime crisp critic crop cross crouch crowd crucial cruel cruise crumble crunch crush cry crystal cube culture cup cupboard curious current curtain curve cushion custom cute cycle dad damage damp dance danger daring dash daughter dawn day deal debate debris decade december decide decline decorate decrease deer defense define defy degree delay deliver demand demise denial dentist deny depart depend deposit depth deputy derive describe desert design desk despair destroy detail detect develop device devote diagram dial diamond diary dice diesel diet differ digital dignity dilemma dinner dinosaur direct dirt disagree discover disease dish dismiss disorder display distance divert divide divorce dizzy doctor document dog doll dolphin domain donate donkey donor door dose double dove draft dragon drama drastic draw dream dress drift drill drink drip drive drop drum dry duck dumb dune during dust dutch duty dwarf dynamic eager eagle early earn earth easily east easy echo ecology economy edge edit educate effort egg eight either elbow elder electric elegant element elephant elevator elite else embark embody embrace emerge emotion employ empower empty enable enact end endless endorse enemy energy enforce engage engine enhance enjoy enlist enough enrich enroll ensure enter entire entry envelope episode equal equip era erase erode erosion error erupt escape essay essence estate eternal ethics evidence evil evoke evolve exact example excess exchange excite exclude excuse execute exercise exhaust exhibit exile exist exit exotic expand expect expire explain expose express extend extra eye eyebrow fabric face faculty fade faint faith fall false fame family famous fan fancy fantasy farm fashion fat fatal father fatigue fault favorite feature february federal fee feed feel female fence festival fetch fever few fiber fiction field figure file film filter final find fine finger finish fire firm first fiscal fish fit fitness fix flag flame flash flat flavor flee flight flip float flock floor flower fluid flush fly foam focus fog foil fold follow food foot force forest forget fork fortune forum forward fossil foster found fox fragile frame frequent fresh friend fringe frog front frost frown frozen fruit fuel fun funny furnace fury future gadget gain galaxy gallery game gap garage garbage garden garlic garment gas gasp gate gather gauge gaze general genius genre gentle genuine gesture ghost giant gift giggle ginger giraffe girl give glad glance glare glass glide glimpse globe gloom glory glove glow glue goat goddess gold good goose gorilla gospel gossip govern gown grab grace grain grant grape grass gravity great green grid grief grit grocery group grow grunt guard guess guide guilt guitar gun gym habit hair half hammer hamster hand happy harbor hard harsh harvest hat have hawk hazard head health heart heavy hedgehog height hello helmet help hen hero hidden high hill hint hip hire history hobby hockey hold hole holiday hollow home honey hood hope horn horror horse hospital host hotel hour hover hub huge human humble humor hundred hungry hunt hurdle hurry hurt husband hybrid ice icon idea identify idle ignore ill illegal illness image imitate immense immune impact impose improve impulse inch include income increase index indicate indoor industry infant inflict inform inhale inherit initial inject injury inmate inner innocent input inquiry insane insect inside inspire install intact interest into invest invite involve iron island isolate issue item ivory jacket jaguar jar jazz jealous jeans jelly jewel job join joke journey joy judge juice jump jungle junior junk just kangaroo keen keep ketchup key kick kid kidney kind kingdom kiss kit kitchen kite kitten kiwi knee knife knock know lab label labor ladder lady lake lamp language laptop large later latin laugh laundry lava law lawn lawsuit layer lazy leader leaf learn leave lecture left leg legal legend leisure lemon lend length lens leopard lesson letter level liar liberty library license life lift light like limb limit link lion liquid list little live lizard load loan lobster local lock logic lonely long loop lottery loud lounge love loyal lucky luggage lumber lunar lunch luxury lyrics machine mad magic magnet maid mail main major make mammal man manage mandate mango mansion manual maple marble march margin marine market marriage mask mass master match material math matrix matter maximum maze meadow mean measure meat mechanic medal media melody melt member memory mention menu mercy merge merit merry mesh message metal method middle midnight milk million mimic mind minimum minor minute miracle mirror misery miss mistake mix mixed mixture mobile model modify mom moment monitor monkey monster month moon moral more morning mosquito mother motion motor mountain mouse move movie much muffin mule multiply muscle museum mushroom music must mutual myself mystery myth naive name napkin narrow nasty nation nature near neck need negative neglect neither nephew nerve nest net network neutral never news next nice night noble noise nominee noodle normal north nose notable note nothing notice novel now nuclear number nurse nut oak obey object oblige obscure observe obtain obvious occur ocean october odor off offer office often oil okay old olive olympic omit once one onion online only open opera opinion oppose option orange orbit orchard order ordinary organ orient original orphan ostrich other outdoor outer output outside oval oven over own owner oxygen oyster ozone pact paddle page pair palace palm panda panel panic panther paper parade parent park parrot party pass patch path patient patrol pattern pause pave payment peace peanut pear peasant pelican pen penalty pencil people pepper perfect permit person pet phone photo phrase physical piano picnic picture piece pig pigeon pill pilot pink pioneer pipe pistol pitch pizza place planet plastic plate play please pledge pluck plug plunge poem poet point polar pole police pond pony pool popular portion position possible post potato pottery poverty powder power practice praise predict prefer prepare present pretty prevent price pride primary print priority prison private prize problem process produce profit program project promote proof property prosper protect proud provide public pudding pull pulp pulse pumpkin punch pupil puppy purchase purity purpose purse push put puzzle pyramid quality quantum quarter question quick quit quiz quote rabbit raccoon race rack radar radio rail rain raise rally ramp ranch random range rapid rare rate rather raven raw razor ready real reason rebel rebuild recall receive recipe record recycle reduce reflect reform refuse region regret regular reject relax release relief rely remain remember remind remove render renew rent reopen repair repeat replace report require rescue resemble resist resource response result retire retreat return reunion reveal review reward rhythm rib ribbon rice rich ride ridge rifle right rigid ring riot ripple risk ritual rival river road roast robot robust rocket romance roof rookie room rose rotate rough round route royal rubber rude rug rule run runway rural sad saddle sadness safe sail salad salmon salon salt salute same sample sand satisfy satoshi sauce sausage save say scale scan scare scatter scene scheme school science scissors scorpion scout scrap screen script scrub sea search season seat second secret section security seed seek segment select sell seminar senior sense sentence series service session settle setup seven shadow shaft shallow share shed shell sheriff shield shift shine ship shiver shock shoe shoot shop short shoulder shove shrimp shrug shuffle shy sibling sick side siege sight sign silent silk silly silver similar simple since sing siren sister situate six size skate sketch ski skill skin skirt skull slab slam sleep slender slice slide slight slim slogan slot slow slush small smart smile smoke smooth snack snake snap sniff snow soap soccer social sock soda soft solar soldier solid solution solve someone song soon sorry sort soul sound soup source south space spare spatial spawn speak special speed spell spend sphere spice spider spike spin spirit split spoil sponsor spoon sport spot spray spread spring spy square squeeze squirrel stable stadium staff stage stairs stamp stand start state stay steak steel stem step stereo stick still sting stock stomach stone stool story stove strategy street strike strong struggle student stuff stumble style subject submit subway success such sudden suffer sugar suggest suit summer sun sunny sunset super supply supreme sure surface surge surprise surround survey suspect sustain swallow swamp swap swarm swear sweet swift swim swing switch sword symbol symptom syrup system table tackle tag tail talent talk tank tape target task taste tattoo taxi teach team tell ten tenant tennis tent term test text thank that theme then theory there they thing this thought three thrive throw thumb thunder ticket tide tiger tilt timber time tiny tip tired tissue title toast tobacco today toddler toe together toilet token tomato tomorrow tone tongue tonight tool tooth top topic topple torch tornado tortoise toss total tourist toward tower town toy track trade traffic tragic train transfer trap trash travel tray treat tree trend trial tribe trick trigger trim trip trophy trouble truck true truly trumpet trust truth try tube tuition tumble tuna tunnel turkey turn turtle twelve twenty twice twin twist two type typical ugly umbrella unable unaware uncle uncover under undo unfair unfold unhappy uniform unique unit universe unknown unlock until unusual unveil update upgrade uphold upon upper upset urban urge usage use used useful useless usual utility vacant vacuum vague valid valley valve van vanish vapor various vast vault vehicle velvet vendor venture venue verb verify version very vessel veteran viable vibrant vicious victory video view village vintage violin virtual virus visa visit visual vital vivid vocal voice void volcano volume vote voyage wage wagon wait walk wall walnut want warfare warm warrior wash wasp waste water wave way wealth weapon wear weasel weather web wedding weekend weird welcome west wet whale what wheat wheel when where whip whisper wide width wife wild will win window wine wing wink winner winter wire wisdom wise wish witness wolf woman wonder wood wool word work world worry worth wrap wreck wrestle wrist write wrong yard year yellow you young youth zebra zero zone zoo'.split(' ');
  const WORD_INDEX = new Map(WORDS.map((word, index) => [word, index]));
  const MAX_CHARACTERS = 65536, MAX_FIELDS = 32, MAX_MATCHES = 8;
  const LABELS = Object.freeze({
    private_key: 'private key', wallet_seed: 'wallet recovery phrase',
    github_token: 'GitHub access token', openai_key: 'OpenAI API key',
    anthropic_key: 'Anthropic API key', stripe_secret_key: 'Stripe live secret key',
    slack_token: 'Slack access token', aws_credentials: 'AWS access credentials'
  });
  const K = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];
  const rotate = (value, count) => (value >>> count) | (value << (32 - count));
  // BIP39 entropy is 16–32 bytes, so SHA-256 always has one padded block.
  // Synchronous validation is necessary before a paste's default insertion.
  function entropyChecksum(entropy) {
    const padded = new Uint8Array(64), view = new DataView(padded.buffer), words = new Int32Array(64);
    padded.set(entropy); padded[entropy.length] = 0x80; view.setUint32(60, entropy.length * 8, false);
    for (let i = 0; i < 16; i++) words[i] = view.getInt32(i * 4, false);
    for (let i = 16; i < 64; i++) {
      const x = words[i - 15], y = words[i - 2];
      const a = rotate(x, 7) ^ rotate(x, 18) ^ (x >>> 3), b = rotate(y, 17) ^ rotate(y, 19) ^ (y >>> 10);
      words[i] = (words[i - 16] + a + words[i - 7] + b) | 0;
    }
    let a = 0x6a09e667, b = 0xbb67ae85, c = 0x3c6ef372, d = 0xa54ff53a,
      e = 0x510e527f, f = 0x9b05688c, g = 0x1f83d9ab, h = 0x5be0cd19;
    for (let i = 0; i < 64; i++) {
      const s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25), ch = (e & f) ^ (~e & g);
      const t1 = (h + s1 + ch + K[i] + words[i]) | 0;
      const s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22), maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (s0 + maj) | 0;
      h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
    }
    return ((a + 0x6a09e667) | 0) >>> 24;
  }
  function validMnemonic(text) {
    if (typeof text !== 'string' || text.length > 1024) return false;
    const words = text.normalize('NFKD').trim().toLowerCase().split(/\s+/);
    if (![12, 15, 18, 21, 24].includes(words.length)) return false;
    let bits = '';
    for (const word of words) {
      const index = WORD_INDEX.get(word); if (index === undefined) return false;
      bits += index.toString(2).padStart(11, '0');
    }
    const entropyLength = Math.floor(bits.length * 32 / 33), checksumLength = bits.length - entropyLength;
    const entropy = new Uint8Array(entropyLength / 8);
    for (let i = 0; i < entropy.length; i++) entropy[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2);
    return bits.slice(entropyLength) === entropyChecksum(entropy).toString(2).padStart(8, '0').slice(0, checksumLength);
  }
  function plausibleToken(value, prefixLength) {
    if (/(?:example|placeholder|redacted|replace[-_]?me|your[-_]?(?:api|secret|token))/i.test(value)) return false;
    if (value.startsWith('github_pat_')) prefixLength = 11;
    if (value.startsWith('sk-ant-api')) prefixLength = /^sk-ant-api\d{2}-/.exec(value)?.[0].length || prefixLength;
    return new Set(value.slice(prefixLength)).size >= 6;
  }
  function privateKeyCount(text) {
    const pattern = /-----BEGIN ((?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY)-----([A-Za-z0-9+/=\s]+?)-----END \1-----/g;
    let count = 0, match;
    while ((match = pattern.exec(text)) && count < MAX_MATCHES) {
      try {
        const encoded = match[2].replace(/\s/g, '');
        if (encoded.length < 64 || encoded.length % 4 !== 0) continue;
        const data = root.atob(encoded);
        if (match[1] === 'OPENSSH PRIVATE KEY') {
          if (data.startsWith('openssh-key-v1\0') && data.length > 48) count++;
          continue;
        }
        if (data.charCodeAt(0) !== 0x30 || data.length < 48) continue;
        let length = data.charCodeAt(1), offset = 2;
        if (length & 0x80) {
          const bytes = length & 0x7f; if (bytes < 1 || bytes > 4 || bytes + 2 > data.length) continue;
          length = 0;
          for (let i = 0; i < bytes; i++) length = length * 256 + data.charCodeAt(offset++);
        }
        if (length === data.length - offset) count++;
      } catch { /* A malformed example is not a confirmed key container. */ }
    }
    return count;
  }
  function detect(text) {
    if (typeof text !== 'string' || !text || text.length > MAX_CHARACTERS) return null;
    const found = [];
    function add(category, count = 1) { if (count) found.push({ category, count }); }
    add('private_key', privateKeyCount(text));
    if (validMnemonic(text)) add('wallet_seed');
    const patterns = [
      ['github_token', /\b(?:gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{60,255})(?![A-Za-z0-9_])/g, 4],
      ['openai_key', /\bsk-proj-[A-Za-z0-9_-]{40,256}(?![A-Za-z0-9_-])/g, 8],
      ['anthropic_key', /\bsk-ant-(?:api\d{2}-)?[A-Za-z0-9_-]{40,256}(?![A-Za-z0-9_-])/g, 7],
      ['stripe_secret_key', /\bsk_live_[A-Za-z0-9]{24,128}(?![A-Za-z0-9])/g, 8],
      ['slack_token', /\bxox[baprs]-[A-Za-z0-9-]{24,256}(?![A-Za-z0-9-])/g, 5]
    ];
    for (const [category, pattern, prefix] of patterns) {
      let count = 0, match;
      while ((match = pattern.exec(text)) && count < MAX_MATCHES) if (plausibleToken(match[0], prefix)) count++;
      add(category, count);
    }
    // An AWS access-key ID is an identifier, not a secret by itself.
    const awsID = /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/.test(text);
    const awsPattern = /(?:aws_secret_access_key|secretAccessKey|secret_access_key)["']?\s*[:=]\s*["']?([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])/gi;
    if (awsID && [...text.matchAll(awsPattern)].some(match => plausibleToken(match[1], 0))) add('aws_credentials');
    if (!found.length) return null;
    const categories = Object.freeze([...new Set(found.map(value => value.category))]);
    return Object.freeze({ category: found[0].category, label: LABELS[found[0].category],
      count: Math.min(MAX_MATCHES, found.reduce((sum, value) => sum + value.count, 0)), categories });
  }
  function shouldBlock(detection, context = {}) {
    if (!detection || !Object.hasOwn(LABELS, detection.category)) return false;
    // Ordinary passwords, OTPs and public keys are never detected. Narrowly
    // allow deliberate credential storage in GitHub's actual secret settings;
    // page labels and a same-origin form alone cannot grant this exception.
    if (detection.category !== 'wallet_seed') {
      try {
        const page = new URL(context.pageURL), destination = new URL(context.destinationURL || page.href, page.href);
        if (page.protocol === 'https:' && page.hostname === 'github.com' && page.port === '' &&
            destination.origin === page.origin &&
            /^\/(?:[^/]+\/[^/]+\/)?settings\/secrets\/(?:actions|codespaces|dependabot)(?:\/|$)/.test(page.pathname)) return false;
      } catch { /* Unknown destination cannot establish a trusted workflow. */ }
    }
    return true;
  }
  function editableTarget(event, window) {
    const target = event.composedPath?.().find(value => value instanceof window.Element) || event.target;
    if (!(target instanceof window.Element)) return null;
    const element = target.closest('input,textarea,[contenteditable]:not([contenteditable="false"])');
    if (!element?.isConnected || element.disabled || element.readOnly) return null;
    if (element.tagName === 'INPUT' && !['text','password','email','search','url','tel'].includes(element.type)) return null;
    return element;
  }
  /// Root content lifecycle owns listeners and availability. This controller
  /// reads clipboard data only inside a trusted user paste event; it has no
  /// clipboardRead permission, clipboard polling, network or persistent store.
  function createGuard(options) {
    const window = options.window || root.window;
    let disposed = false, generation = 0;
    const pending = new Map();
    function eligible(event) {
      return !disposed && event?.isTrusted === true && event.cancelable !== false && !event.defaultPrevented &&
        options.isActive() === true && options.isAvailable() === true;
    }
    function signal(event, target, detection, phase) {
      let context;
      try { context = options.contextForTarget?.(target) || { pageURL: window.location.href }; }
      catch { return false; }
      if (!shouldBlock(detection, context)) return false;
      event.preventDefault(); event.stopImmediatePropagation?.();
      const metadata = Object.freeze({ category: detection.category, label: detection.label,
        count: detection.count, categories: detection.categories, phase });
      const stamp = generation, token = {};
      const timer = window.setTimeout(() => {
        if (!pending.delete(token) || disposed || stamp !== generation) return;
        options.onUnavailable?.(metadata);
      }, Math.min(3000, Math.max(250, options.deliveryTimeoutMS || 1000)));
      pending.set(token, timer);
      // Only bounded static category metadata and the local DOM reference are
      // handed off. Raw paste/field values are neither retained nor replayed.
      Promise.resolve().then(() => {
        if (disposed || stamp !== generation || !pending.has(token)) return false;
        return options.notify(metadata, target);
      }).then(result => {
        if (!pending.delete(token)) return;
        window.clearTimeout(timer);
        if (!disposed && stamp === generation && result !== true && result?.ok !== true)
          options.onUnavailable?.(metadata);
      }, () => {
        if (!pending.delete(token)) return;
        window.clearTimeout(timer);
        if (!disposed && stamp === generation) options.onUnavailable?.(metadata);
      });
      return true;
    }
    function paste(event) {
      if (!eligible(event)) return false;
      const target = editableTarget(event, window); if (!target) return false;
      let detection;
      try { detection = detect(event.clipboardData?.getData('text/plain') || event.clipboardData?.getData('text') || ''); }
      catch { return false; }
      return detection ? signal(event, target, detection, 'paste') : false;
    }
    function submit(event) {
      if (!eligible(event) || !(event.target instanceof window.HTMLFormElement)) return false;
      for (const field of [...event.target.elements].slice(0, MAX_FIELDS)) {
        if (!field.isConnected || field.disabled || typeof field.value !== 'string' || field.type === 'hidden') continue;
        const detection = detect(field.value);
        if (detection && signal(event, field, detection, 'submit')) return true;
      }
      return false;
    }
    function dispose() {
      disposed = true; generation++;
      for (const timer of pending.values()) window.clearTimeout(timer);
      pending.clear();
    }
    return Object.freeze({ paste, submit, dispose });
  }
  const api = Object.freeze({ detect, validMnemonic, shouldBlock, createGuard, labels: LABELS,
    limits: Object.freeze({ maximumCharacters: MAX_CHARACTERS, maximumFields: MAX_FIELDS }),
    englishWords: () => [...WORDS] });
  root.MuseGuardSecrets = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(globalThis);
