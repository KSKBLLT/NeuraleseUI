import json
import sys

def main():
    BASE_SYMBOLS = ['[pad]', '[bos]', '[end]', '.', ',', '!', '?', ':', ';', '-', '\'', '\"', '(', ')', '[', ']']
    PIECES = ['The', 'cat', 'sat', 'on', 'the', 'mat', '.', 'rug', 'floor', 'grass', 'bed', ' ']

    raw_tokens = json.load(open('resources/tokenizers/vocab_tokens.json', 'r', encoding='utf-8'))

    vocab = [None] * 8192
    seen = set()

    # 0..15: BASE_SYMBOLS
    for i, s in enumerate(BASE_SYMBOLS):
        vocab[i] = s
        seen.add(s)

    # 16..27: PIECES
    for i, p in enumerate(PIECES):
        idx = 16 + i
        vocab[idx] = p
        seen.add(p)

    # 256..511: Byte tokens <0x00> .. <0xFF>
    for b in range(256):
        byte_tok = f'<0x{b:02X}>'
        vocab[256 + b] = byte_tok
        # Do not add byte_tok to seen so normal text matching doesn't match raw byte syntax unless desired

    # Basic characters to add into 28..255
    chars = ' abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZабвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ0123456789/\\+=*&%$#@_~<>↵⇥·\n\t\r'
    idx = 28
    for c in chars:
        if c not in seen and idx < 256:
            vocab[idx] = c
            seen.add(c)
            idx += 1

    priority_words = [
        'Привет', 'мир', 'как', 'дела', 'нейросеть', 'модель', 'токен', 'словарь', 'текст', 'ответ',
        'кот', 'сидел', 'на', 'коврике', 'собака', 'дом', 'человек', 'время', 'день', 'ночь', 'окно',
        'стол', 'мама', 'мыла', 'раму', 'привет', 'хорошо', 'да', 'нет', 'что', 'это', 'все', 'он', 'она',
        'hello', 'world', 'language', 'token', 'model', 'neural', 'network', 'input', 'output', 'train',
        'layer', 'attention', 'embedding', 'dense', 'softmax', 'test', 'data', 'good', 'morning', 'cat',
        'sat', 'mat', 'dog', 'run', 'walk', 'see', 'look', 'make', 'take', 'come', 'go', 'know', 'think'
    ]
    # Add priority words (both with space and plain)
    for w in priority_words:
        for candidate in [' ' + w, w]:
            if candidate not in seen:
                if idx < 256:
                    vocab[idx] = candidate
                    seen.add(candidate)
                    idx += 1

    # Fill remaining from 512..8191
    idx = 512
    # First any remaining priority words
    for w in priority_words:
        for candidate in [' ' + w, w]:
            if candidate not in seen and idx < 8192:
                vocab[idx] = candidate
                seen.add(candidate)
                idx += 1

    # Fill with HuggingFace tokens
    for t in raw_tokens:
        if t is not None and t != '' and t not in seen and idx < 8192:
            vocab[idx] = t
            seen.add(t)
            idx += 1

    # In case 28..255 has empty slots, fill them from idx
    for i in range(28, 256):
        if vocab[i] is None:
            for t in raw_tokens:
                if t is not None and t != '' and t not in seen:
                    vocab[i] = t
                    seen.add(t)
                    break

    # In case 512..8192 has empty slots:
    for i in range(512, 8192):
        if vocab[i] is None:
            vocab[i] = f'[token_{i}]'

    print('Vocab built, total length:', len(vocab), 'none count:', vocab.count(None))
    with open('resources/tokenizers/vocab_tokens.json', 'w', encoding='utf-8') as f:
        json.dump(vocab, f, ensure_ascii=False)
    print('Saved resources/tokenizers/vocab_tokens.json successfully!')

if __name__ == '__main__':
    main()
