# frozen-string-literal: true

require 'csv'

input = ARGV[0]
output = ARGV[1]

records = []
props = {
  'hatoma:id' => '例文行番号',
  'hatoma:ex_sid' => '例文SID',
  'hatoma:ex_sound' => '例文音声ファイル',
  'URI' => '例文音声ファイル',
  'hatoma:ex' => '例文Ex',
  'hatoma:ex_ipa' => '例文IPA',
  'hatoma:ex_trs' => '例文Trs',
  'hatoma:ex_wid' => '語彙WdID',
  'hatoma:ex_hid' => '語彙Order',
  'dcterms:title' => '例文Ex',
  'dcterms:description' => '例文Trs'
}

def untag(txt)
  tag = /\\ruby(?<ruby_opt>\[[^\[\]]+\])?\{(?<ruby_base>[^{}]+)\}\{(?<ruby_txt>[^{}]+)\}/

  txt
    .gsub('{SqBr}', '[')
    .gsub('{/SqBr}', ']')
    .gsub('{f}', '(')
    .gsub('{/f}', ')')
    .gsub('{EOS}', '。')
    .gsub('{EOS!}', '!')
    .gsub tag do |_|
      m = Regexp.last_match
      if m[:ruby_opt] == '[g]' || m[:ruby_opt] == '{SqBr}g{/SqBr}'
        "#{m[:ruby_base]}(#{m[:ruby_txt]})"
      else
        m[:ruby_base].split('').zip(m[:ruby_txt].split('|')).map { |b, t| "#{b}(#{t})" }.join
      end
    end
end

CSV.foreach input, col_sep: "\t", headers: true, liberal_parsing: true do |row|
  next unless row['例文行番号'] && row['語彙WdID']

  records << props.to_h do |k, h|
    case k
    when 'URI'
      [
        k,
        !row[h] || row[h] == 'x' ? nil : "https://github.com/yf-wang-ninjal/hatoma/raw/main/htm_reibun/#{row[h].sub '.wav', '.mp3'}"
      ]
    # when 'hatoma:ex_hlink'
    #   [k, "https://ninda.ninjal.ac.jp/s/hatoma/headword/#{row[h]}"]
    when 'hatoma:id'
      [k, row[h].to_i + 1_000_000]
    when 'dcterms:description', 'hatoma:ex_trs', 'hatoma:ex_ipa'
      [k, untag(row[h])]
    else
      [k, row[h]]
    end
  end
end

File.open output, 'w:utf-8' do |out|
  out.puts props.keys.join("\t")
  records.each do |r|
    out.puts props.keys.map { |k| r[k] }.join("\t")
  end
end
