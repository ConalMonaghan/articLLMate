# Claude


Pipeline takes articles in xml folder or an R object (prefer the R object) see how this is structured below. All inputs will be in a folder in the input folder.

It then runs each sequentially through either the API or eventually API batch. But leave batch blank for now as a placeholder, but important that you know. 

Then we run each article through the LLM and extract the output.Storing the results in an R object. The output R object should be the same as the input, but now with the results. Don't manipuate or alter the input object, make a new one that is the same but with the output object. 

The input object will be called the publisher name, then have the doi for the articles as the seecond layer. E.g.,

> SPRINGER_Clean$`10.1007_s10964-015-0252-x`$XML$Text

##
All options in these object are outlined below. 

APA_Clean$`2014-02644-001`$XML$Title
APA_Clean$`2014-02644-001`$XML$DOI
APA_Clean$`2014-02644-001`$XML$Text
APA_Clean$`2014-02644-001`$EXTRACTED_DOI
APA_Clean$`2014-02644-001`$META


head(str(APA_Clean))

$ 2014-36705-001:List of 3
  ..$ XML          :List of 3
  .. ..$ Title: chr "Can psychoanalysis reclaim the public sphere?"
  .. ..$ DOI  : chr "10.1037/a0037857"
  .. ..$ Text : chr "When approaching the shores of the United States of America, Freud famously told Jung and Ferenczi: \"They don'"| __truncated__
  ..$ EXTRACTED_DOI: chr "10.1037/a0037857"
  ..$ META         : tibble [1 × 27] (S3: tbl_df/tbl/data.frame)
  .. ..$ alternative.id        : chr "2014-36705-001"
  .. ..$ container.title       : chr "Psychoanalytic Psychology"
  .. ..$ created               : chr "2014-09-08"
  .. ..$ deposited             : chr "2024-02-06"
  .. ..$ published.online      : chr "2015-04"
  .. ..$ doi                   : chr "10.1037/a0037857"
  .. ..$ indexed               : chr "2024-03-01"
  .. ..$ issn                  : chr "1939-1331,0736-9735"
  .. ..$ issue                 : chr "2"
  .. ..$ issued                : chr "2015-04"
  .. ..$ member                : chr "15"
  .. ..$ page                  : chr "293-306"
  .. ..$ prefix                : chr "10.1037"
  .. ..$ publisher             : chr "American Psychological Association (APA)"
  .. ..$ score                 : chr "1"
  .. ..$ source                : chr "Crossref"
  .. ..$ reference.count       : chr "0"
  .. ..$ references.count      : chr "0"
  .. ..$ is.referenced.by.count: chr "2"
  .. ..$ title                 : chr "Can psychoanalysis reclaim the public sphere?"
  .. ..$ type                  : chr "journal-article"
  .. ..$ url                   : chr "https://doi.org/10.1037/a0037857"
  .. ..$ volume                : chr "32"
  .. ..$ language              : chr "en"
  .. ..$ short.container.title : chr "Psychoanalytic Psychology"
  .. ..$ author                :List of 1
  .. .. ..$ : tibble [1 × 3] (S3: tbl_df/tbl/data.frame)
  .. .. .. ..$ given   : chr "Carlo"
  .. .. .. ..$ family  : chr "Strenger"
  .. .. .. ..$ sequence: chr "first"
  .. ..$ link                  :List of 1
  .. .. ..$ : tibble [1 × 4] (S3: tbl_df/tbl/data.frame)
  .. .. .. ..$ URL                 : chr "http://psycnet.apa.org/journals/pap/32/2/293.pdf"
  .. .. .. ..$ content.type        : chr "unspecified"
  .. .. .. ..$ content.version     : chr "vor"
  .. .. .. ..$ intended.application: chr "similarity-checking"
 $ 2014-36706-001:List of 3
  ..$ XML          :List of 3
  .. ..$ Title: chr "Chronotope disruption as a sensitizing concept for understanding chronic illness narratives."
  .. ..$ DOI  : chr "10.1037/hea0000151"
  .. ..$ Text : chr "In this article, we elaborate a little-investigated aspect of chronic illness narratives: the grounding of biog"| __truncated__
  ..$ EXTRACTED_DOI: chr "10.1037/hea0000151"
  ..$ META         : tibble [1 × 29] (S3: tbl_df/tbl/data.frame)
  .. ..$ alternative.id        : chr "2014-36706-001,25197985"
  .. ..$ container.title       : chr "Health Psychology"
  .. ..$ created               : chr "2014-09-08"
  .. ..$ deposited             : chr "2024-02-06"
  .. ..$ published.online      : chr "2015-04"
  .. ..$ doi                   : chr "10.1037/hea0000151"
  .. ..$ indexed               : chr "2026-01-06"
  .. ..$ issn                  : chr "1930-7810,0278-6133"
  .. ..$ issue                 : chr "4"
  .. ..$ issued                : chr "2015-04"
  .. ..$ member                : chr "15"
  .. ..$ page                  : chr "407-416"
  .. ..$ prefix                : chr "10.1037"
  .. ..$ publisher             : chr "American Psychological Association (APA)"
  .. ..$ score                 : chr "1"
  .. ..$ source                : chr "Crossref"
  .. ..$ reference.count       : chr "0"
  .. ..$ references.count      : chr "0"
  .. ..$ is.referenced.by.count: chr "10"
  .. ..$ title                 : chr "Chronotope disruption as a sensitizing concept for understanding chronic illness narratives."
  .. ..$ type                  : chr "journal-article"
  .. ..$ url                   : chr "https://doi.org/10.1037/hea0000151"
  .. ..$ volume                : chr "34"
  .. ..$ language              : chr "en"
  .. ..$ short.container.title : chr "Health Psychology"
  .. ..$ author                :List of 1
  .. .. ..$ : tibble [2 × 3] (S3: tbl_df/tbl/data.frame)
  .. .. .. ..$ given   : chr [1:2] "Tim" "Anna"
  .. .. .. ..$ family  : chr [1:2] "Gomersall" "Madill"
  .. .. .. ..$ sequence: chr [1:2] "first" "additional"
  .. ..$ funder                :List of 1
  .. .. ..$ : tibble [1 × 1] (S3: tbl_df/tbl/data.frame)
  .. .. .. ..$ name: chr "MRC/ESRC"
  .. ..$ link                  :List of 1
  .. .. ..$ : tibble [1 × 4] (S3: tbl_df/tbl/data.frame)
  .. .. .. ..$ URL                 : chr "http://psycnet.apa.org/journals/hea/34/4/407.pdf"
  .. .. .. ..$ content.type        : chr "unspecified"
  .. .. .. ..$ content.version     : chr "vor"
  .. .. .. ..$ intended.application: chr "similarity-checking"
  .. ..$ license               :List of 1
  .. .. ..$ : tibble [1 × 4] (S3: tbl_df/tbl/data.frame)
  .. .. .. ..$ date           : chr "2014-09-08"
  .. .. .. ..$ content.version: chr "vor"
  .. .. .. ..$ delay.in.days  : int 0
  .. .. .. ..$ URL            : chr "http://creativecommons.org/licenses/by/3.0/"
 $ 2014-37302-001:List of 3


## Then each R object has 6000-14000 articles


# To do


### Updates for Claude to change

### New input style
 input style is now Robjects. (RDS). Each article is indexed by their doi at the second level of the object, Then we need to select xml then text. E.g,.
 > SPRINGER_Clean$`10.1007_s10964-015-0252-x`$XML$Text
 [1] "Alcohol and illicit drug use are often initiated during the critical developmental periods of adolescence and early adulthood. In 2012, an 
 estimated 15 % of 12-20 years olds reported binge drinking in the past month (five or more drinks on the same occasion) and 4 % could be classified 
 as heavy drinkers (five or more drinks on the same occasion for five or more days) (SAMHSA 2013). Further, among youth aged 12-17, 7.2 

Paste the text below the title, e.g., 

APA_Clean$`2013-44735-001`$XML$Title
[1] "Evaluating measurement of dynamic constructs: Defining a measurement model of derivatives."

Note that there will be many many articles. 


### API addition

# Add gemini as a api provider option
# E.g.,  "gemini" = c("gemini", "json"),

## Local models

# Make the new check local models check and ensure the local models are good to go for the main pipeline
# Local models will be setup in 00_3 which you need to write. We need to setup this earlier you will see in the 00_1 stage to make sure reticulate etc is setup.
# I want this to run on both Mac and PC (w cuda). Happy to just use ollama. At the beginning of the 00_3, also have a section that lets the user see what models are there, 
# and a simple line to show them how to download new models if they need. 
# you will see that the run code for api and local are differnet. This is important. Keep them seperate. 

#at("\n========== STEP 0: Environment Check ==========\n")    
#qwen3-coder:30b     06c1097efce0    18 GB    2 months ago    
#deepseek-r1:32b     edba8017331d    19 GB    2 months ago   

# this for now, however, I want to be able to download others then just add them. 