module Ask
  # Common English and Spanish short forms of first names, so "Bob Smith" finds Robert
  # Smith and "Chuy Ramos" finds Jesus Ramos. Lookups work both ways: a nickname expands
  # to its formal names and a formal name to its nicknames, so asking about "Robert" also
  # finds someone entered as "Bob". Keys and values are lowercase ASCII, as tokens are.
  module Nicknames
    MAP = {
      # English
      "al" => %w[albert alfred alan allen], "alex" => %w[alexander alejandro alexandra alexis],
      "andy" => %w[andrew andres], "drew" => %w[andrew], "barb" => %w[barbara], "becky" => %w[rebecca],
      "ben" => %w[benjamin], "beth" => %w[elizabeth], "betty" => %w[elizabeth], "bill" => %w[william],
      "billy" => %w[william], "will" => %w[william], "willie" => %w[william], "liam" => %w[william],
      "bob" => %w[robert], "bobby" => %w[robert], "rob" => %w[robert], "robbie" => %w[robert],
      "bert" => %w[robert albert], "cathy" => %w[catherine], "charlie" => %w[charles], "chuck" => %w[charles],
      "chris" => %w[christopher christian christina christine], "dan" => %w[daniel], "danny" => %w[daniel],
      "dave" => %w[david], "davey" => %w[david], "debbie" => %w[deborah], "don" => %w[donald],
      "doug" => %w[douglas], "ed" => %w[edward eduardo], "eddie" => %w[edward eduardo], "ted" => %w[edward theodore],
      "frank" => %w[francis franklin francisco], "fred" => %w[frederick alfred], "gabe" => %w[gabriel],
      "greg" => %w[gregory], "hank" => %w[henry], "jake" => %w[jacob], "jeff" => %w[jeffrey],
      "jen" => %w[jennifer], "jenny" => %w[jennifer], "jerry" => %w[gerald jerome], "jim" => %w[james],
      "jimmy" => %w[james], "jamie" => %w[james], "joe" => %w[joseph], "joey" => %w[joseph],
      "john" => %w[jonathan], "johnny" => %w[john jonathan], "jack" => %w[john], "jon" => %w[jonathan john],
      "josh" => %w[joshua], "kate" => %w[katherine kathryn catherine], "katie" => %w[katherine kathryn catherine],
      "kathy" => %w[katherine kathryn], "ken" => %w[kenneth], "kenny" => %w[kenneth], "kim" => %w[kimberly],
      "larry" => %w[lawrence], "liz" => %w[elizabeth], "lizzie" => %w[elizabeth], "maggie" => %w[margaret],
      "meg" => %w[margaret], "manny" => %w[manuel], "matt" => %w[matthew], "mike" => %w[michael],
      "mikey" => %w[michael], "mick" => %w[michael], "nate" => %w[nathan nathaniel], "nick" => %w[nicholas],
      "nicky" => %w[nicholas], "pat" => %w[patrick patricia], "pete" => %w[peter], "phil" => %w[phillip philip],
      "ray" => %w[raymond], "rick" => %w[richard ricardo], "ricky" => %w[richard ricardo], "rich" => %w[richard],
      "richie" => %w[richard], "ron" => %w[ronald], "ronnie" => %w[ronald], "sam" => %w[samuel samantha],
      "sammy" => %w[samuel], "steve" => %w[steven stephen], "stevie" => %w[steven stephen], "sue" => %w[susan],
      "terry" => %w[terrence teresa], "tim" => %w[timothy], "timmy" => %w[timothy], "tom" => %w[thomas],
      "tommy" => %w[thomas], "tony" => %w[anthony antonio], "vic" => %w[victor], "vince" => %w[vincent],
      "zach" => %w[zachary],
      # Spanish
      "beto" => %w[alberto roberto], "chema" => %w[jose], "chuy" => %w[jesus], "fer" => %w[fernando],
      "juanito" => %w[juan], "lalo" => %w[eduardo], "lupe" => %w[guadalupe], "memo" => %w[guillermo],
      "nacho" => %w[ignacio], "paco" => %w[francisco], "pancho" => %w[francisco], "pepe" => %w[jose],
      "quique" => %w[enrique], "rafa" => %w[rafael], "tono" => %w[antonio], "lucho" => %w[luis],
      "chepe" => %w[jose], "toni" => %w[antonio antonia], "guille" => %w[guillermo]
    }.freeze

    REVERSE = MAP.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(nickname, names), reverse|
      names.each { |name| reverse[name] << nickname }
    end.transform_values(&:freeze).freeze

    module_function

    # Other spellings of one first-name token, the token itself excluded:
    #   Ask::Nicknames.expand("bob")    # => ["robert"]
    #   Ask::Nicknames.expand("robert") # => ["bob", "bobby", "rob", "robbie", "bert"]
    def expand(token)
      (MAP.fetch(token, []) + REVERSE.fetch(token, [])).uniq - [ token ]
    end
  end
end
