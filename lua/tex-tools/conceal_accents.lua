-- Precomposed Unicode equivalents of single-letter LaTeX accents.
-- Generated from Unicode NFC; unsupported combinations retain their source.
local accents = {}
accents["'"] = {
  source = 'ACEGIKLMNOPRSUWYZacegiklmnoprsuwyz',
  target = 'ÁĆÉǴÍḰĹḾŃÓṔŔŚÚẂÝŹáćéǵíḱĺḿńóṕŕśúẃýź',
}
accents['`'] = { source = 'AEINOUWYaeinouwy', target = 'ÀÈÌǸÒÙẀỲàèìǹòùẁỳ' }
accents['^'] =
  { source = 'ACEGHIJOSUWYZaceghijosuwyz', target = 'ÂĈÊĜĤÎĴÔŜÛŴŶẐâĉêĝĥîĵôŝûŵŷẑ' }
accents['"'] = { source = 'AEHIOUWXYaehiotuwxy', target = 'ÄËḦÏÖÜẄẌŸäëḧïöẗüẅẍÿ' }
accents['~'] = { source = 'AEINOUVYaeinouvy', target = 'ÃẼĨÑÕŨṼỸãẽĩñõũṽỹ' }
accents['='] = { source = 'AEGIOUYaegiouy', target = 'ĀĒḠĪŌŪȲāēḡīōūȳ' }
accents['.'] = {
  source = 'ABCDEFGHIMNOPRSTWXYZabcdefghmnoprstwxyz',
  target = 'ȦḂĊḊĖḞĠḢİṀṄȮṖṘṠṪẆẊẎŻȧḃċḋėḟġḣṁṅȯṗṙṡṫẇẋẏż',
}
accents['u'] = { source = 'AEGIOUaegiou', target = 'ĂĔĞĬŎŬăĕğĭŏŭ' }
accents['v'] = {
  source = 'ACDEGHIKLNORSTUZacdeghijklnorstuz',
  target = 'ǍČĎĚǦȞǏǨĽŇǑŘŠŤǓŽǎčďěǧȟǐǰǩľňǒřšťǔž',
}
accents['H'] = { source = 'OUou', target = 'ŐŰőű' }
accents['c'] = { source = 'CDEGHKLNRSTcdeghklnrst', target = 'ÇḐȨĢḨĶĻŅŖŞŢçḑȩģḩķļņŗşţ' }
accents['k'] = { source = 'AEIOUaeiou', target = 'ĄĘĮǪŲąęįǫų' }
accents['r'] = { source = 'AUauwy', target = 'ÅŮåůẘẙ' }
accents['b'] = { source = 'BDKLNRTZbdhklnrtz', target = 'ḆḎḴḺṈṞṮẔḇḏẖḵḻṉṟṯẕ' }
accents['d'] = {
  source = 'ABDEHIKLMNORSTUVWYZabdehiklmnorstuvwyz',
  target = 'ẠḄḌẸḤỊḲḶṂṆỌṚṢṬỤṾẈỴẒạḅḍẹḥịḳḷṃṇọṛṣṭụṿẉỵẓ',
}
for name, pair in pairs(accents) do
  local values = vim.fn.split(pair.target, '\\zs')
  local map = {}
  for i = 1, #pair.source do
    map[pair.source:sub(i, i)] = values[i]
  end
  accents[name] = map
end

return accents
