#!/usr/bin/bash
# shortcuts that I offen use for convert / ImageMagick
if [[ "$1" == "" ]]; then
	echo "Usage: opt.sh [input] [command=optimize]";
	echo "Command Result";
	echo "------- ---------------------------------------------------"
	echo "default Optimize image while maintaining size"
	echo "resize  Optimize image and resize to 800px on longest axis"
	echo "square  Optimize image and resize to a 250px square for thumbs"
	exit;
fi

# if there's no incoming file then bail
if [[ ! -f "$1" ]]; then
	echo "There is no file $1 that you speak of here.";
	exit;
fi

# move the original so we do not overwrite since things are permanent
EXT=".${1##*.}"
ORIG=$(echo "$1" | sed "s/$EXT/.orig$EXT/")
mv "$1" "$ORIG"

# start the command with the normal optimizing stuffs
CMD="convert $ORIG -strip -sampling-factor 4:2:0 -quality 85 -interlace JPEG -colorspace RGB"

# resize to 800 to make megapixel images not so mega
if [[ "$2" == "resize" ]]; then
	echo "Optimize and resize";
	CMD=$CMD" -resize 800x800"

fi;

# cut out the square of the middle of the image and resize to 250px
if [[ "$2" == "square" ]]; then
	echo "Optimize and Square";
	CMD=$CMD" -gravity Center -extent 1:1 -resize 250x250"

fi

CMD=$CMD" $1"
bash -c "$CMD"



echo "I'm done, my dude"

